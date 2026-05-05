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
  # rubocop:disable Metrics/ClassLength
  class RailsCacheAdapter
    include StaleWhileRevalidate

    GENERATION_MEMO_TTL_SECONDS = 1.0

    # @return [Integer] Time-to-live in seconds
    attr_reader :ttl

    # @return [String] Cache key namespace
    attr_reader :namespace

    # @return [Integer] Lock timeout in seconds for stampede protection
    attr_reader :lock_timeout

    # @return [Integer] Stale TTL for SWR in seconds
    attr_reader :stale_ttl

    # @return [Concurrent::CachedThreadPool, nil] Thread pool for background refreshes
    attr_reader :thread_pool

    # @return [Logger] Logger instance for error reporting
    attr_reader :logger

    # Initialize a new Rails.cache adapter
    #
    # @param ttl [Integer] Time-to-live in seconds (default: 60)
    # @param namespace [String] Cache key namespace (default: "langfuse")
    # @param lock_timeout [Integer] Lock timeout in seconds for stampede protection (default: 10)
    # @param stale_ttl [Integer] Stale TTL for SWR in seconds (default: 0, SWR disabled).
    #   Note: :indefinite is normalized to 1000 years by Config before being passed here.
    # @param refresh_threads [Integer] Number of background refresh threads (default: 5)
    # @param logger [Logger, nil] Logger instance for error reporting (default: nil, creates new logger)
    # @raise [ConfigurationError] if Rails.cache is not available
    def initialize(ttl: 60, namespace: "langfuse", lock_timeout: 10, stale_ttl: 0, refresh_threads: 5,
                   logger: default_logger)
      validate_rails_cache!

      @ttl = ttl
      @namespace = namespace
      @namespace_prefix = "#{namespace}:"
      @lock_timeout = lock_timeout
      @stale_ttl = stale_ttl
      @logger = logger
      @generation_memo = {}
      @generation_memo_mutex = Mutex.new
      initialize_swr(refresh_threads: refresh_threads) if swr_enabled?
    end

    # Get a value from the cache
    #
    # @param key [String] Cache key
    # @return [Object, nil] Cached value or nil if not found/expired
    def get(key)
      Rails.cache.read(namespaced_key(key))
    end

    # Read a raw cache entry, including stale entries.
    #
    # @param key [String] Cache key
    # @return [Object, nil] Raw cache entry
    def entry(key)
      Rails.cache.read(namespaced_key(key))
    end

    # Set a value in the cache
    #
    # @param key [String] Cache key
    # @param value [Object] Value to cache
    # @return [Object] The cached value
    def set(key, value, ttl: nil, stale_ttl: nil)
      # Calculate expiration: use total_ttl if SWR enabled, otherwise just ttl
      effective_ttl = ttl.nil? ? self.ttl : ttl
      effective_stale_ttl = stale_ttl.nil? ? self.stale_ttl : stale_ttl
      expires_in = swr_enabled? ? effective_ttl + effective_stale_ttl : effective_ttl
      Rails.cache.write(namespaced_key(key), value, expires_in:)
      value
    end

    # Delete one generated storage key.
    #
    # @param key [String] Cache key
    # @return [Boolean] true if an entry was removed
    def delete(key)
      Rails.cache.delete(namespaced_key(key))
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
      clear_generation_memo
    end

    # Logically invalidate every generated storage key.
    #
    # @return [Integer] New global generation
    def clear_logically
      bump_generation(global_generation_key)
    end

    # Logically invalidate every cache variant for one prompt name.
    #
    # @param name [String] Prompt name
    # @return [Integer] New name generation
    def invalidate_name(name)
      bump_generation(name_generation_key(name))
    end

    # Build a generated storage key for the current cache generation.
    #
    # @param logical_key [String] Stable logical cache identity
    # @param name [String] Prompt name
    # @return [String] Generated storage key
    def storage_key(logical_key, name:)
      generated = PromptCache.storage_key(
        logical_key,
        name: name,
        global_generation: generation_value(global_generation_key),
        name_generation: generation_value(name_generation_key(name))
      )
      namespaced_key(generated)
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

    # @return [Hash] Prompt cache statistics
    def stats
      {
        backend: "rails",
        enabled: true,
        current_generation_entries: nil,
        orphaned_entries: nil,
        total_entries: nil,
        global_generation: generation_value(global_generation_key),
        unsupported_counts: %i[current_generation_entries orphaned_entries total_entries]
      }
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

    # Validate that Rails.cache is available for prompt caching.
    #
    # @return [Boolean]
    # @raise [ConfigurationError] if Rails.cache is not available
    # rubocop:disable Naming/PredicateMethod
    def validate!
      validate_rails_cache!
      true
    end
    # rubocop:enable Naming/PredicateMethod

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
    def fetch_with_lock(key, ttl: nil)
      # 1. Check cache first (fast path - no lock needed)
      cached = get(key)
      return cached if cached

      # 2. Cache miss - try to acquire lock
      lock_key = build_lock_key(key)

      if acquire_lock(lock_key)
        begin
          # We got the lock - fetch from source and populate cache
          value = yield
          set(key, value, ttl: ttl)
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
      entry(key)
    end

    # Set value in cache (SWR interface)
    #
    # @param key [String] Cache key
    # @param value [Object] Value to cache (expects CacheEntry)
    # @return [Object] The cached value
    def cache_set(key, value, ttl: nil)
      Rails.cache.write(namespaced_key(key), value, expires_in: ttl || total_ttl)
      value
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
      key.start_with?(@namespace_prefix) ? key : "#{@namespace_prefix}#{key}"
    end

    def global_generation_key
      namespaced_key("__prompt_cache_generation__:global")
    end

    def name_generation_key(name)
      encoded_name = Base64.urlsafe_encode64(name.to_s, padding: false)
      namespaced_key("__prompt_cache_generation__:name:#{encoded_name}")
    end

    def generation_value(key)
      now = monotonic_time
      memoized = memoized_generation_value(key, now)
      return memoized unless memoized.nil?

      Rails.cache.read(key).to_i.tap do |value|
        memoize_generation_value(key, value, now)
      end
    end

    def bump_generation(key)
      incremented = increment_generation(key)
      if incremented
        memoize_generation_value(key, incremented.to_i)
        return incremented
      end

      new_value = generation_value(key) + 1
      Rails.cache.write(key, new_value)
      memoize_generation_value(key, new_value)
      new_value
    end

    def increment_generation(key)
      return unless Rails.cache.respond_to?(:increment)

      Rails.cache.write(key, 0, unless_exist: true)
      Rails.cache.increment(key, 1)
    rescue StandardError => e
      logger.warn("Langfuse prompt cache generation increment failed for key '#{key}': #{e.class} - #{e.message}")
      nil
    end

    def memoized_generation_value(key, now)
      @generation_memo_mutex.synchronize do
        entry = @generation_memo[key]
        return nil unless entry

        return entry.fetch(:value) if now < entry.fetch(:expires_at)

        @generation_memo.delete(key)
        nil
      end
    end

    def memoize_generation_value(key, value, now = monotonic_time)
      @generation_memo_mutex.synchronize do
        @generation_memo[key] = { value: value, expires_at: now + GENERATION_MEMO_TTL_SECONDS }
      end
    end

    def clear_generation_memo
      @generation_memo_mutex.synchronize do
        @generation_memo.clear
      end
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
  # rubocop:enable Metrics/ClassLength
end
