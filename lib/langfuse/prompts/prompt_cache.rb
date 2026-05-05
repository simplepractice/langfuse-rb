# frozen_string_literal: true

require "monitor"
require "base64"
require_relative "../stale_while_revalidate"

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
  # rubocop:disable Metrics/ClassLength
  class PromptCache
    include StaleWhileRevalidate

    # Caps the per-name generation map. Without a cap, long-lived processes
    # that invalidate across many distinct prompts grow it unboundedly; LRU
    # eviction keeps the working set live and lets cold names go.
    MAX_NAME_GENERATIONS = 1024

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

    # @return [Integer] Time-to-live in seconds
    attr_reader :ttl

    # @return [Integer] Maximum number of cache entries
    attr_reader :max_size

    # @return [Integer] Stale TTL for SWR in seconds
    attr_reader :stale_ttl

    # @return [Logger] Logger instance for error reporting
    attr_reader :logger

    # Initialize a new cache
    #
    # @param ttl [Integer] Time-to-live in seconds (default: 60)
    # @param max_size [Integer] Maximum cache size (default: 1000)
    # @param stale_ttl [Integer] Stale TTL for SWR in seconds (default: 0, SWR disabled).
    #   Note: :indefinite is normalized to 1000 years by Config before being passed here.
    # @param refresh_threads [Integer] Number of background refresh threads (default: 5)
    # @param logger [Logger, nil] Logger instance for error reporting (default: nil, creates new logger)
    def initialize(ttl: 60, max_size: 1000, stale_ttl: 0, refresh_threads: 5, logger: default_logger)
      @ttl = ttl
      @max_size = max_size
      @stale_ttl = stale_ttl
      @logger = logger
      @cache = {}
      @global_generation = 0
      @name_generations = {}
      @name_generation_counter = 0
      @monitor = Monitor.new
      @locks = {} # Track locks for in-memory locking
      initialize_swr(refresh_threads: refresh_threads) if swr_enabled?
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

    # Read a raw cache entry, including stale entries.
    #
    # @param key [String] Cache key
    # @return [CacheEntry, nil] Raw cache entry
    def entry(key)
      @monitor.synchronize do
        @cache[key]
      end
    end

    # Set a value in the cache
    #
    # @param key [String] Cache key
    # @param value [Object] Value to cache
    # @return [Object] The cached value
    def set(key, value, ttl: nil, stale_ttl: nil)
      @monitor.synchronize do
        # Evict oldest entry if at max size
        evict_oldest if @cache.size >= max_size
        # TTL math is inlined (not extracted to a helper) to keep this hot path
        # allocation-free apart from the CacheEntry below.
        effective_ttl = ttl.nil? ? self.ttl : ttl
        effective_stale_ttl = stale_ttl.nil? ? self.stale_ttl : stale_ttl
        fresh_until = Time.now + effective_ttl
        @cache[key] = CacheEntry.new(value, fresh_until, fresh_until + effective_stale_ttl)
        value
      end
    end

    # Delete one generated storage key.
    #
    # @param key [String] Generated storage key
    # @return [Boolean] true if an entry was removed
    def delete(key)
      @monitor.synchronize do
        !@cache.delete(key).nil?
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

    # Logically invalidate every generated storage key.
    #
    # @return [Integer] New global generation
    def clear_logically
      @monitor.synchronize do
        @global_generation += 1
      end
    end

    # Logically invalidate every cache variant for one prompt name.
    #
    # Generations come from a monotonic global counter, not a per-name counter,
    # so an evicted name re-entering the map can't reuse a generation value
    # that's still embedded in a stale @cache entry.
    #
    # @param name [String] Prompt name
    # @return [Integer] New name generation
    def invalidate_name(name)
      @monitor.synchronize do
        name_str = name.to_s
        @name_generations.delete(name_str)
        @name_generations.shift if @name_generations.size >= MAX_NAME_GENERATIONS
        @name_generation_counter += 1
        @name_generations[name_str] = @name_generation_counter
      end
    end

    # Build a generated storage key for the current cache generation.
    #
    # @param logical_key [String] Stable logical cache identity
    # @param name [String] Prompt name
    # @return [String] Generated storage key
    def storage_key(logical_key, name:)
      @monitor.synchronize do
        self.class.storage_key(
          logical_key,
          name: name,
          global_generation: @global_generation,
          name_generation: @name_generations.fetch(name.to_s, 0)
        )
      end
    end

    # @return [Hash] Prompt cache statistics
    def stats
      @monitor.synchronize do
        counts = count_entries_by_generation
        {
          backend: CacheBackend::MEMORY,
          enabled: true,
          current_generation_entries: counts.fetch(:current),
          orphaned_entries: counts.fetch(:orphaned),
          total_entries: @cache.size,
          ttl: ttl,
          size: @cache.size,
          max_size: max_size,
          global_generation: @global_generation,
          unsupported_counts: []
        }
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

    # Validate that the memory cache backend is usable.
    #
    # @return [Boolean]
    # rubocop:disable Naming/PredicateMethod
    def validate!
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
      key = name.to_s
      key += ":v#{version}" if version
      key += ":#{label}" if label
      key += ":production" unless version || label
      key
    end

    # Build a generated storage key from generation metadata.
    #
    # @param logical_key [String] Stable logical cache identity
    # @param name [String] Prompt name
    # @param global_generation [Integer] Global cache generation
    # @param name_generation [Integer] Prompt-name cache generation
    # @return [String] Generated storage key
    def self.storage_key(logical_key, name:, global_generation:, name_generation:)
      encoded_name = Base64.urlsafe_encode64(name.to_s, padding: false)
      "g#{global_generation}:n#{encoded_name}:#{name_generation}:#{logical_key}"
    end

    private

    # Implementation of StaleWhileRevalidate abstract methods

    # Get value from cache (SWR interface)
    #
    # @param key [String] Cache key
    # @return [PromptCache::CacheEntry, nil] Cached value
    def cache_get(key)
      @monitor.synchronize do
        @cache[key]
      end
    end

    # Set value in cache (SWR interface)
    #
    # @param key [String] Cache key
    # @param value [PromptCache::CacheEntry] Value to cache
    # @return [PromptCache::CacheEntry] The cached value
    def cache_set(key, value, **_options)
      @monitor.synchronize do
        # Evict oldest entry if at max size
        evict_oldest if @cache.size >= max_size

        @cache[key] = value
        value
      end
    end

    # Acquire a lock using in-memory locking
    #
    # Prevents duplicate background refreshes from different threads within
    # the same process. This is NOT distributed locking - it only works
    # within a single process. For distributed locking, use RailsCacheAdapter.
    #
    # **MEMORY LEAK WARNING**: Locks are stored in a hash and only deleted on
    # release_lock. If a refresh thread crashes or is killed externally (e.g., Thread#kill)
    # between acquire_lock and release_lock, the lock persists forever. Unlike Redis locks
    # which have TTL expiration, in-memory locks have no timeout. For production use with
    # SWR, prefer RailsCacheAdapter to avoid lock accumulation and potential memory exhaustion.
    #
    # @param lock_key [String] Lock key
    # @return [Boolean] true if lock was acquired, false if already held
    def acquire_lock(lock_key)
      @monitor.synchronize do
        return false if @locks[lock_key]

        @locks[lock_key] = true
        true
      end
    end

    # Release a lock
    #
    # @param lock_key [String] Lock key
    # @return [void]
    def release_lock(lock_key)
      @monitor.synchronize do
        @locks.delete(lock_key)
      end
    end

    def count_entries_by_generation
      @cache.each_key.with_object({ current: 0, orphaned: 0 }) do |key, counts|
        if current_generation_key?(key)
          counts[:current] += 1
        else
          counts[:orphaned] += 1
        end
      end
    end

    def current_generation_key?(key)
      parts = key.split(":", 4)
      return false unless parts.size == 4
      return false unless parts[0].start_with?("g") && parts[1].start_with?("n")

      global = Integer(parts[0][1..])
      name = Base64.urlsafe_decode64(parts[1][1..])
      name_generation = Integer(parts[2])
      global == @global_generation && name_generation == @name_generations.fetch(name, 0)
    rescue ArgumentError
      false
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
  # rubocop:enable Metrics/ClassLength
end
