# frozen_string_literal: true

require "concurrent"

module Langfuse
  # Stale-While-Revalidate caching pattern module
  #
  # Provides SWR functionality for cache implementations. When included,
  # allows serving stale data immediately while refreshing in the background.
  #
  # Including classes must implement:
  # - cache_get(key) - Read from cache
  # - cache_set(key, value, expires_in:) - Write to cache
  # - acquire_lock(lock_key) - Acquire lock for background refresh
  # - release_lock(lock_key) - Release refresh lock
  #
  # @example
  #   class MyCache
  #     include Langfuse::StaleWhileRevalidate
  #
  #     def initialize(ttl: 60, stale_ttl: nil)
  #       @ttl = ttl
  #       @stale_ttl = StaleWhileRevalidate.normalize_stale_ttl(stale_ttl || ttl)
  #       @logger = Logger.new($stdout)
  #       initialize_swr
  #     end
  #
  #     def cache_get(key)
  #       @storage[key]
  #     end
  #
  #     def cache_set(key, value, expires_in:)
  #       @storage[key] = value
  #     end
  #
  #     def acquire_lock(lock_key)
  #       # Implementation-specific lock acquisition
  #     end
  #
  #     def release_lock(lock_key)
  #       # Implementation-specific lock release
  #     end
  #   end
  # rubocop:disable Metrics/ModuleLength
  module StaleWhileRevalidate
    # Number of seconds in 1000 years (accounting for leap years)
    THOUSAND_YEARS_IN_SECONDS = (1000 * 365.25 * 24 * 60 * 60).to_i

    # Normalize stale_ttl value
    #
    # Converts Float::INFINITY to 1000 years in seconds for practical "never expire"
    # behavior while keeping the value finite for calculations.
    #
    # @param stale_ttl [Integer, Float::INFINITY] Stale TTL value (required, no nil allowed)
    # @return [Integer] Normalized stale TTL in seconds
    #
    # @example
    #   StaleWhileRevalidate.normalize_stale_ttl(300) # => 300
    #   StaleWhileRevalidate.normalize_stale_ttl(Float::INFINITY) # => 31557600000
    def self.normalize_stale_ttl(stale_ttl)
      return THOUSAND_YEARS_IN_SECONDS if stale_ttl == Float::INFINITY

      stale_ttl
    end

    # Initialize SWR infrastructure
    #
    # Must be called by including class after setting @stale_ttl, @ttl, and @logger.
    # Typically called in the class's initialize method when stale_ttl is provided.
    #
    # @param refresh_threads [Integer] Number of background refresh threads (default: 5)
    # @return [void]
    def initialize_swr(refresh_threads: 5)
      @thread_pool = initialize_thread_pool(refresh_threads)
    end

    # Fetch a value from cache with Stale-While-Revalidate support
    #
    # This method implements SWR caching: serves stale data immediately while
    # refreshing in the background. Requires SWR to be enabled (stale_ttl must be positive).
    #
    # Three cache states:
    # - FRESH: Return immediately, no action needed
    # - STALE: Return stale data + trigger background refresh
    # - EXPIRED: Must fetch fresh data synchronously
    #
    # @param key [String] Cache key
    # @yield Block to execute to fetch fresh data
    # @return [Object] Cached, stale, or freshly fetched value
    # @raise [ConfigurationError] if SWR is not enabled (stale_ttl is not positive)
    #
    # @example
    #   cache.fetch_with_stale_while_revalidate("greeting:v1") do
    #     api_client.get_prompt("greeting")
    #   end
    def fetch_with_stale_while_revalidate(key, &)
      raise ConfigurationError, "fetch_with_stale_while_revalidate requires a positive stale_ttl" unless swr_enabled?

      entry = cache_get(key)

      if entry&.fresh?
        # FRESH - return immediately
        logger.debug("CACHE HIT!")
        entry.data
      elsif entry&.stale?
        # REVALIDATE - return stale + refresh in background
        logger.debug("CACHE STALE!")
        schedule_refresh(key, &)
        entry.data # Instant response!
      else
        # MISS - must fetch synchronously
        logger.debug("CACHE MISS!")
        fetch_and_cache(key, &)
      end
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
    #
    # TODO: Revert changes to this method to the original implementation
    # since this path is only taken if SWR is not enabled
    def fetch_with_lock(key)
      # 1. Check cache first (fast path - no lock needed)
      cached = cache_get(key)
      return cached if cached

      # 2. Cache miss - try to acquire lock
      lock_key = build_lock_key(key)

      if acquire_lock(lock_key)
        begin
          # We got the lock - fetch from source and populate cache
          value = yield
          cache_set_simple(key, value)
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

    # Check if SWR is enabled
    #
    # SWR is enabled when stale_ttl > ttl, meaning there's a grace period
    # where stale data can be served while revalidating in the background.
    #
    # @return [Boolean] true if stale_ttl is greater than ttl
    def swr_enabled?
      stale_ttl.positive?
    end

    # Shutdown the cache refresh thread pool gracefully
    #
    # @return [void]
    def shutdown
      return unless @thread_pool

      @thread_pool.shutdown
      @thread_pool.wait_for_termination(5) # Wait up to 5 seconds
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
    # Prevents duplicate refreshes by using a fetch lock. If another process/thread
    # is already refreshing this key, this method returns immediately.
    #
    # Errors during refresh are caught and logged to prevent thread crashes.
    #
    # @param key [String] Cache key
    # @yield Block to execute to fetch fresh data
    # @return [void]
    def schedule_refresh(key, &block)
      # Prevent duplicate refreshes
      lock_key = build_lock_key(key)
      return unless acquire_lock(lock_key)

      @thread_pool.post do
        value = yield block
        set_cache_entry(key, value)
      rescue StandardError => e
        logger.error("Langfuse cache refresh failed for key '#{key}': #{e.class} - #{e.message}")
      ensure
        release_lock(lock_key)
      end
    end

    # Fetch data and cache it with SWR metadata
    #
    # @param key [String] Cache key
    # @yield Block to execute to fetch fresh data
    # @return [Object] Freshly fetched value
    def fetch_and_cache(key, &block)
      value = yield block
      set_cache_entry(key, value)
    end

    # Set value in cache with SWR metadata (CacheEntry)
    #
    # @param key [String] Cache key
    # @param value [Object] Value to cache
    # @return [Object] The cached value
    def set_cache_entry(key, value)
      now = Time.now
      fresh_until = now + ttl
      stale_until = fresh_until + stale_ttl
      entry = PromptCache::CacheEntry.new(value, fresh_until, stale_until)

      cache_set(key, entry, expires_in: total_ttl)

      value
    end

    # Set value in cache without SWR metadata (simple value)
    #
    # Used by fetch_with_lock when SWR is disabled.
    #
    # @param key [String] Cache key
    # @param value [Object] Value to cache
    # @return [Object] The cached value
    def cache_set_simple(key, value)
      cache_set(key, value, expires_in: ttl)
      value
    end

    # Build a lock key for fetch operations
    #
    # Can be overridden by including class if custom key format is needed.
    #
    # @param key [String] Cache key
    # @return [String] Lock key
    def build_lock_key(key)
      "#{key}:lock"
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
        cached = cache_get(key)
        return cached if cached
      end

      nil # Cache still empty after all retries
    end

    # Calculate total TTL (fresh + stale)
    #
    # @return [Integer] Total TTL in seconds
    def total_ttl
      ttl + stale_ttl
    end

    # Abstract methods that must be implemented by including class

    # Get a value from cache
    #
    # @param key [String] Cache key
    # @return [Object, nil] Cached value or nil
    # @raise [NotImplementedError] if not implemented by including class
    def cache_get(_key)
      raise NotImplementedError, "#{self.class} must implement #cache_get"
    end

    # Set a value in cache
    #
    # @param key [String] Cache key
    # @param value [Object] Value to cache
    # @param expires_in [Integer] TTL in seconds
    # @return [Object] The cached value
    # @raise [NotImplementedError] if not implemented by including class
    def cache_set(_key, _value, expires_in:)
      raise NotImplementedError, "#{self.class} must implement #cache_set"
    end

    # Acquire a lock
    #
    # @param lock_key [String] Lock key
    # @return [Boolean] true if lock was acquired
    # @raise [NotImplementedError] if not implemented by including class
    def acquire_lock(_lock_key)
      raise NotImplementedError, "#{self.class} must implement #acquire_lock"
    end

    # Release a lock
    #
    # @param lock_key [String] Lock key
    # @return [void]
    # @raise [NotImplementedError] if not implemented by including class
    def release_lock(_lock_key)
      raise NotImplementedError, "#{self.class} must implement #release_lock"
    end

    # Get TTL value
    #
    # @return [Integer] TTL in seconds
    # @raise [NotImplementedError] if not implemented by including class
    def ttl
      @ttl || raise(NotImplementedError, "#{self.class} must provide @ttl")
    end

    # Get stale TTL value
    #
    # @return [Integer] Stale TTL in seconds
    # @raise [NotImplementedError] if not implemented by including class
    def stale_ttl
      @stale_ttl || raise(NotImplementedError, "#{self.class} must provide @stale_ttl")
    end

    # Get logger instance
    #
    # @return [Logger] Logger instance
    # @raise [NotImplementedError] if not implemented by including class
    def logger
      @logger || raise(NotImplementedError, "#{self.class} must provide @logger")
    end
  end
  # rubocop:enable Metrics/ModuleLength
end
