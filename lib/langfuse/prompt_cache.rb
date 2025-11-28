# frozen_string_literal: true

require "monitor"

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

    attr_reader :ttl, :max_size

    # Initialize a new cache
    #
    # @param ttl [Integer] Time-to-live in seconds (default: 60)
    # @param max_size [Integer] Maximum cache size (default: 1000)
    def initialize(ttl: 60, max_size: 1000)
      @ttl = ttl
      @max_size = max_size
      @cache = {}
      @monitor = Monitor.new
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
    # @return [Object] The cached value
    def set(key, value)
      @monitor.synchronize do
        # Evict oldest entry if at max size
        evict_oldest if @cache.size >= max_size

        now = Time.now
        fresh_until = now + ttl
        stale_until = now + ttl
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

    # Evict the oldest entry from cache
    #
    # @return [void]
    def evict_oldest
      return if @cache.empty?

      # Find entry with earliest expiration (using stale_until as expiration time)
      oldest_key = @cache.min_by { |_key, entry| entry.stale_until }&.first
      @cache.delete(oldest_key) if oldest_key
    end
  end
end
