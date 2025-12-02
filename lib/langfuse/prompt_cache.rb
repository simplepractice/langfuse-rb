# frozen_string_literal: true

require "monitor"
require_relative "stale_while_revalidate"

module Langfuse
  # Simple in-memory cache for prompt data with TTL
  #
  # Thread-safe cache implementation for storing prompt responses
  # with time-to-live expiration.
  #
  # @example
  #   cache = Langfuse::PromptCache.new(ttl: 60)
  #   cache.set("greeting:1", prompt_data)
  #   cache.get("greeting:1") # => prompt_data
  #
  class PromptCache
    include StaleWhileRevalidate

    # Cache entry with data and expiration time
    #
    # Supports stale-while-revalidate pattern:
    # - fresh_until: Time until entry is considered fresh (can be served immediately)
    # - stale_until: Time until entry is considered stale (serve while revalidating in background)
    # - After stale_until: Entry is expired (must revalidate synchronously)
    CacheEntry = Struct.new(:data, :fresh_until, :stale_until) do
      # Check if the cache entry is still fresh
      #
      # @return [Boolean] true if current time is before fresh_until
      def fresh?
        Time.now < fresh_until
      end

      # Check if the cache entry is stale but not expired
      #
      # Stale entries can be served immediately while a background
      # revalidation occurs (stale-while-revalidate pattern)
      #
      # @return [Boolean] true if current time is between fresh_until and stale_until
      def stale?
        now = Time.now
        now >= fresh_until && now < stale_until
      end

      # Check if the cache entry has expired
      #
      # Expired entries should not be served and must be revalidated
      # synchronously before use.
      #
      # @return [Boolean] true if current time is at or after stale_until
      def expired?
        Time.now >= stale_until
      end
    end

    attr_reader :ttl, :max_size, :stale_ttl, :logger

    # Initialize a new cache
    #
    # @param ttl [Integer] Time-to-live in seconds (default: 60)
    # @param max_size [Integer] Maximum cache size (default: 1000)
    # @param stale_ttl [Integer, nil] Stale TTL for SWR (default: nil, disabled)
    # @param refresh_threads [Integer] Number of background refresh threads (default: 5)
    # @param logger [Logger, nil] Logger instance for error reporting (default: nil, creates new logger)
    def initialize(ttl: 60, max_size: 1000, stale_ttl: nil, refresh_threads: 5, logger: default_logger)
      @ttl = ttl
      @max_size = max_size
      @stale_ttl = stale_ttl
      @logger = logger
      @cache = {}
      @monitor = Monitor.new
      @locks = {} # Track locks for in-memory locking
      initialize_swr(refresh_threads: refresh_threads) if stale_ttl
    end

    # Get a value from the cache
    #
    # @param key [String] Cache key
    # @return [Object, nil] Cached value or nil if not found/expired
    def get(key)
      @monitor.synchronize do
        entry = @cache[key]
        return nil unless entry
        return nil if entry.expired?

        entry.data
      end
    end

    # Set a value in the cache
    #
    # @param key [String] Cache key
    # @param value [Object] Value to cache
    # @param expires_in [Integer] Optional TTL override (default: uses @ttl)
    # @return [Object] The cached value
    def set(key, value, expires_in: ttl)
      @monitor.synchronize do
        # Evict oldest entry if at max size
        evict_oldest if @cache.size >= max_size

        now = Time.now
        fresh_until = now + expires_in
        stale_until = now + expires_in
        @cache[key] = CacheEntry.new(value, fresh_until, stale_until)
        value
      end
    end

    # Clear the entire cache
    #
    # @return [void]
    def clear
      @monitor.synchronize do
        @cache.clear
      end
    end

    # Remove expired entries from cache
    #
    # @return [Integer] Number of entries removed
    def cleanup_expired
      @monitor.synchronize do
        initial_size = @cache.size
        @cache.delete_if { |_key, entry| entry.expired? }
        initial_size - @cache.size
      end
    end

    # Get current cache size
    #
    # @return [Integer] Number of entries in cache
    def size
      @monitor.synchronize do
        @cache.size
      end
    end

    # Check if cache is empty
    #
    # @return [Boolean]
    def empty?
      @monitor.synchronize do
        @cache.empty?
      end
    end

    # Build a cache key from prompt name and options
    #
    # @param name [String] Prompt name
    # @param version [Integer, nil] Optional version
    # @param label [String, nil] Optional label
    # @return [String] Cache key
    def self.build_key(name, version: nil, label: nil)
      key = name.to_s
      key += ":v#{version}" if version
      key += ":#{label}" if label
      key
    end

    private

    # Implementation of StaleWhileRevalidate abstract methods

    # Get value from cache (SWR interface)
    #
    # @param key [String] Cache key
    # @return [Object, nil] Cached value
    def cache_get(key)
      @monitor.synchronize do
        @cache[key]
      end
    end

    # Set value in cache (SWR interface)
    #
    # @param key [String] Cache key
    # @param value [Object] Value to cache
    # @param expires_in [Integer] TTL in seconds
    # @return [Object] The cached value
    def cache_set(key, value, expires_in: nil)
      @monitor.synchronize do
        # Evict oldest entry if at max size
        evict_oldest if @cache.size >= max_size

        # NOTE: expires_in is accepted for interface compatibility with StaleWhileRevalidate
        # but not used here since CacheEntry objects manage their own expiration times
        _ = expires_in
        @cache[key] = value
        value
      end
    end

    # Acquire a refresh lock using in-memory locking
    #
    # @param lock_key [String] Lock key
    # @return [Boolean] true if lock was acquired, false if already held
    def acquire_refresh_lock(lock_key)
      @monitor.synchronize do
        return false if @locks[lock_key]

        @locks[lock_key] = true
        true
      end
    end

    # Release a refresh lock
    #
    # @param lock_key [String] Lock key
    # @return [void]
    def release_refresh_lock(lock_key)
      @monitor.synchronize do
        @locks.delete(lock_key)
      end
    end

    # In-memory cache helper methods

    # Evict the oldest entry from cache
    #
    # @return [void]
    def evict_oldest
      return if @cache.empty?

      # Find entry with earliest expiration (using stale_until as expiration time)
      oldest_key = @cache.min_by { |_key, entry| entry.stale_until }&.first
      @cache.delete(oldest_key) if oldest_key
    end

    # Create a default logger
    #
    # @return [Logger]
    def default_logger
      Logger.new($stdout, level: Logger::WARN)
    end
  end
end
