# frozen_string_literal: true

require "concurrent"
require "logger"
require_relative "prompt_cache"

module Langfuse
  # rubocop:disable Metrics/ClassLength
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
    attr_reader :ttl, :namespace, :lock_timeout, :stale_ttl, :thread_pool, :logger

    # Initialize a new Rails.cache adapter
    #
    # @param ttl [Integer] Time-to-live in seconds (default: 60)
    # @param namespace [String] Cache key namespace (default: "langfuse")
    # @param lock_timeout [Integer] Lock timeout in seconds for stampede protection (default: 10)
    # @param stale_ttl [Integer, nil] Stale TTL for SWR (default: nil, disabled)
    # @param refresh_threads [Integer] Number of background refresh threads (default: 5)
    # @param logger [Logger, nil] Logger instance for error reporting (default: nil, creates new logger)
    # @raise [ConfigurationError] if Rails.cache is not available
    def initialize(ttl: 60, namespace: "langfuse", lock_timeout: 10, stale_ttl: nil, refresh_threads: 5, logger: nil)
      validate_rails_cache!

      @ttl = ttl
      @namespace = namespace
      @lock_timeout = lock_timeout
      @stale_ttl = stale_ttl
      @logger = logger || default_logger
      @thread_pool = initialize_thread_pool(refresh_threads) if stale_ttl
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
    def set(key, value, expires_in: ttl)
      Rails.cache.write(namespaced_key(key), value, expires_in:)
      value
    end

    # Fetch a value from cache with Stale-While-Revalidate support
    #
    # This method implements SWR caching: serves stale data immediately while
    # refreshing in the background. Falls back to fetch_with_lock if SWR is disabled.
    #
    # Three cache states:
    # - FRESH: Return immediately, no action needed
    # - STALE: Return stale data + trigger background refresh
    # - EXPIRED: Must fetch fresh data synchronously
    #
    # @param key [String] Cache key
    # @yield Block to execute to fetch fresh data
    # @return [Object] Cached, stale, or freshly fetched value
    #
    # @example
    #   adapter.fetch_with_stale_while_revalidate("greeting:v1") do
    #     api_client.get_prompt("greeting")
    #   end
    def fetch_with_stale_while_revalidate(key, &)
      # TODO: perhaps this should raise an error to make it more explicit that SWR is disabled?
      return fetch_with_lock(key, &) unless stale_ttl

      entry = get(key)

      if entry&.fresh?
        # FRESH - return immediately
        logger.debug("CACHE HIT!")
        entry.data
      elsif entry&.stale?
        # REVALIDATE - return stale + refresh in background
        logger.debug("CACHE STALE!")
        schedule_refresh(key, &)
        entry.data # Instant response! ✨
      else
        # MISS - must fetch synchronously
        logger.debug("CACHE MISS!")
        fetch_and_cache(key, &)
      end
    end

    # Fetch a value from cache with distributed lock for stampede protection
    #
    # This method prevents cache stampedes (thundering herd) by ensuring only one
    # process fetches from the source when the cache is empty. Other processes wait
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
    #   adapter.fetch_with_lock("greeting:v1") do
    #     api_client.get_prompt("greeting")
    #   end
    def fetch_with_lock(key)
      # 1. Check cache first (fast path - no lock needed)
      cached = get(key)
      return cached if cached

      # 2. Cache miss - try to acquire distributed lock
      lock_key = "#{namespaced_key(key)}:lock"

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

    # Shutdown the thread pool gracefully
    #
    # @return [void]
    def shutdown
      return unless thread_pool

      thread_pool.shutdown
      thread_pool.wait_for_termination(5) # Wait up to 5 seconds
    end

    private

    # Initialize thread pool for background refresh operations
    #
    # @param refresh_threads [Integer] Maximum number of refresh threads
    # @return [Concurrent::CachedThreadPool]
    def initialize_thread_pool(refresh_threads)
      Concurrent::CachedThreadPool.new(
        max_threads: refresh_threads,
        min_threads: 2,
        max_queue: 50,
        fallback_policy: :discard # Drop oldest if queue full
      )
    end

    # Schedule a background refresh for a cache key
    #
    # Prevents duplicate refreshes by using a refresh lock. If another process
    # is already refreshing this key, this method returns immediately.
    #
    # Errors during refresh are caught and logged to prevent thread crashes.
    #
    # @param key [String] Cache key
    # @yield Block to execute to fetch fresh data
    # @return [void]
    def schedule_refresh(key)
      # Prevent duplicate refreshes
      refresh_lock_key = "#{namespaced_key(key)}:refreshing"
      return unless acquire_refresh_lock(refresh_lock_key)

      thread_pool.post do
        value = yield
        set_cache_entry(key, value)
      rescue StandardError => e
        logger.error("Langfuse cache refresh failed for key '#{key}': #{e.class} - #{e.message}")
      ensure
        release_lock(refresh_lock_key)
      end
    end

    # Fetch data and cache it with SWR metadata
    #
    # @param key [String] Cache key
    # @yield Block to execute to fetch fresh data
    # @return [Object] Freshly fetched value
    def fetch_and_cache(key)
      value = yield
      set_cache_entry(key, value)
    end

    # Set value in cache with SWR metadata
    #
    # @param key [String] Cache key
    # @param value [Object] Value to cache
    # @return [Object] The cached value
    def set_cache_entry(key, value)
      now = Time.now
      fresh_until = now + ttl
      stale_until = fresh_until + stale_ttl
      entry = PromptCache::CacheEntry.new(value, fresh_until, stale_until)

      set(key, entry, expires_in: total_ttl)

      value
    end

    # Acquire a refresh lock to prevent duplicate background refreshes
    #
    # TODO: check if we can reuse the same lock acquisition logic for cache refreshes and
    # fetches with lock.
    #
    # @param lock_key [String] Full lock key (already namespaced)
    # @return [Boolean] true if lock was acquired, false if already held
    def acquire_refresh_lock(lock_key)
      Rails.cache.write(
        lock_key,
        true,
        unless_exist: true, # Atomic: only write if key doesn't exist
        expires_in: 60 # Short-lived lock for background refreshes
      )
    end

    # Add namespace prefix to cache key
    #
    # @param key [String] Original cache key
    # @return [String] Namespaced cache key
    def namespaced_key(key)
      "#{namespace}:#{key}"
    end

    # Acquire a distributed lock using Rails.cache
    #
    # Uses atomic "write if not exists" operation to ensure only one process
    # can acquire the lock.
    #
    # @param lock_key [String] Full lock key (already namespaced)
    # @return [Boolean] true if lock was acquired, false if already held by another process
    def acquire_lock(lock_key)
      Rails.cache.write(
        lock_key,
        true,
        unless_exist: true, # Atomic: only write if key doesn't exist
        expires_in: lock_timeout # Auto-expire to prevent deadlocks
      )
    end

    # Release a distributed lock
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
    # @param key [String] Cache key (not namespaced)
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

    def total_ttl
      ttl + stale_ttl
    end
  end
  # rubocop:enable Metrics/ClassLength
end
