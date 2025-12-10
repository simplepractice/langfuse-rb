# frozen_string_literal: true

require_relative "prompt_cache"
require_relative "stale_while_revalidate"

module Langfuse
  # Rails.cache adapter for distributed caching with Redis
  #
  # Wraps Rails.cache to provide distributed caching for prompts across
  # multiple processes and servers. Requires Rails with Redis cache store.
  #
  # @example
  #   adapter = Langfuse::RailsCacheAdapter.new(ttl: 60)
  #   adapter.set("greeting:1", prompt_data)
  #   adapter.get("greeting:1") # => prompt_data
  #
  class RailsCacheAdapter
    include StaleWhileRevalidate

    attr_reader :ttl, :namespace, :lock_timeout, :stale_ttl, :thread_pool, :logger

    # Initialize a new Rails.cache adapter
    #
    # @param ttl [Integer] Time-to-live in seconds (default: 60)
    # @param namespace [String] Cache key namespace (default: "langfuse")
    # @param lock_timeout [Integer] Lock timeout in seconds for stampede protection (default: 10)
    # @param stale_ttl [Integer, Float::INFINITY, nil] Stale TTL for SWR (default: 0, SWR disabled). Use Float::INFINITY for 1000 years, e.g. non-expiring cache.
    # @param refresh_threads [Integer] Number of background refresh threads (default: 5)
    # @param logger [Logger, nil] Logger instance for error reporting (default: nil, creates new logger)
    # @raise [ConfigurationError] if Rails.cache is not available
    def initialize(ttl: 60, namespace: "langfuse", lock_timeout: 10, stale_ttl: 0, refresh_threads: 5,
                   logger: default_logger)
      validate_rails_cache!

      @ttl = ttl
      @namespace = namespace
      @lock_timeout = lock_timeout
      @stale_ttl = StaleWhileRevalidate.normalize_stale_ttl(stale_ttl)
      @logger = logger
      initialize_swr(refresh_threads: refresh_threads) if swr_enabled?
    end

    # Get a value from the cache
    #
    # @param key [String] Cache key
    # @return [Object, nil] Cached value or nil if not found/expired
    def get(key)
      Rails.cache.read(namespaced_key(key))
    end

    # Set a value in the cache
    #
    # @param key [String] Cache key
    # @param value [Object] Value to cache
    # @return [Object] The cached value
    def set(key, value)
      # Calculate expiration: use total_ttl if SWR enabled, otherwise just ttl
      expires_in = swr_enabled? ? total_ttl : ttl
      Rails.cache.write(namespaced_key(key), value, expires_in:)
      value
    end

    # Clear the entire Langfuse cache namespace
    #
    # Note: This uses delete_matched which may not be available on all cache stores.
    # Works with Redis, Memcached, and memory stores. File store support varies.
    #
    # @return [void]
    def clear
      # Delete all keys matching the namespace pattern
      Rails.cache.delete_matched("#{namespace}:*")
    end

    # Get current cache size
    #
    # Note: Rails.cache doesn't provide a size method, so we return nil
    # to indicate this operation is not supported.
    #
    # @return [nil]
    def size
      nil
    end

    # Check if cache is empty
    #
    # Note: Rails.cache doesn't provide an efficient way to check if empty,
    # so we return false to indicate this operation is not supported.
    #
    # @return [Boolean] Always returns false (unsupported operation)
    def empty?
      false
    end

    # Build a cache key from prompt name and options
    #
    # @param name [String] Prompt name
    # @param version [Integer, nil] Optional version
    # @param label [String, nil] Optional label
    # @return [String] Cache key
    def self.build_key(name, version: nil, label: nil)
      PromptCache.build_key(name, version: version, label: label)
    end

    # Fetch a value from cache with lock for stampede protection
    #
    # This method prevents cache stampedes (thundering herd) by ensuring only one
    # process/thread fetches from the source when the cache is empty. Others wait
    # for the first one to populate the cache.
    #
    # Uses exponential backoff: 50ms, 100ms, 200ms (3 retries max, ~350ms total).
    # If cache is still empty after waiting, falls back to fetching from source.
    #
    # @param key [String] Cache key
    # @yield Block to execute if cache miss (should fetch fresh data)
    # @return [Object] Cached or freshly fetched value
    #
    # @example
    #   cache.fetch_with_lock("greeting:v1") do
    #     api_client.get_prompt("greeting")
    #   end
    def fetch_with_lock(key)
      # 1. Check cache first (fast path - no lock needed)
      cached = get(key)
      return cached if cached

      # 2. Cache miss - try to acquire lock
      lock_key = build_lock_key(key)

      if acquire_lock(lock_key)
        begin
          # We got the lock - fetch from source and populate cache
          value = yield
          set(key, value)
          value
        ensure
          # Always release lock, even if block raises
          release_lock(lock_key)
        end
      else
        # Someone else has the lock - wait for them to populate cache
        cached = wait_for_cache(key)
        return cached if cached

        # Cache still empty after waiting - fall back to fetching ourselves
        # (This handles cases where lock holder crashed or took too long)
        yield
      end
    end

    private

    # Implementation of StaleWhileRevalidate abstract methods

    # Get value from cache (SWR interface)
    #
    # @param key [String] Cache key
    # @return [Object, nil] Cached value
    def cache_get(key)
      get(key)
    end

    # Set value in cache (SWR interface)
    #
    # @param key [String] Cache key
    # @param value [Object] Value to cache (expects CacheEntry)
    # @return [Object] The cached value
    def cache_set(key, value)
      set(key, value)
    end

    # Build lock key with namespace
    #
    # Used for both fetch operations (stampede protection) and refresh operations
    # (preventing duplicate background refreshes).
    #
    # @param key [String] Cache key
    # @return [String] Namespaced lock key
    def build_lock_key(key)
      "#{namespaced_key(key)}:lock"
    end

    # Acquire a lock using Rails.cache
    #
    # Used for both fetch operations and refresh operations.
    # Uses the configured lock_timeout for all locking scenarios.
    #
    # @param lock_key [String] Full lock key (already namespaced)
    # @return [Boolean] true if lock was acquired, false if already held
    def acquire_lock(lock_key)
      Rails.cache.write(
        lock_key,
        true,
        unless_exist: true, # Atomic: only write if key doesn't exist
        expires_in: lock_timeout # Use configured lock timeout
      )
    end

    # Release a lock
    #
    # Used for both fetch and refresh operations.
    #
    # @param lock_key [String] Full lock key (already namespaced)
    # @return [void]
    def release_lock(lock_key)
      Rails.cache.delete(lock_key)
    end

    # Wait for cache to be populated by lock holder
    #
    # Uses exponential backoff: 50ms, 100ms, 200ms (3 retries, ~350ms total).
    # This gives the lock holder time to fetch and populate the cache.
    #
    # @param key [String] Cache key
    # @return [Object, nil] Cached value if found, nil if still empty after waiting
    def wait_for_cache(key)
      intervals = [0.05, 0.1, 0.2] # 50ms, 100ms, 200ms (exponential backoff)

      intervals.each do |interval|
        sleep(interval)
        cached = get(key)
        return cached if cached
      end

      nil # Cache still empty after all retries
    end

    # Rails.cache-specific helper methods

    # Add namespace prefix to cache key
    #
    # @param key [String] Original cache key
    # @return [String] Namespaced cache key
    def namespaced_key(key)
      "#{namespace}:#{key}"
    end

    # Validate that Rails.cache is available
    #
    # @raise [ConfigurationError] if Rails.cache is not available
    # @return [void]
    def validate_rails_cache!
      return if defined?(Rails) && Rails.respond_to?(:cache)

      raise ConfigurationError,
            "Rails.cache is not available. Rails cache backend requires Rails with a configured cache store."
    end

    # Create a default logger
    #
    # @return [Logger]
    def default_logger
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger
      else
        Logger.new($stdout, level: Logger::WARN)
      end
    end
  end
end
