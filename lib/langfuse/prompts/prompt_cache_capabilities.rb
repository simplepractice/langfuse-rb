# frozen_string_literal: true

module Langfuse
  # Centralizes optional prompt-cache backend capabilities.
  #
  # @api private
  class PromptCacheCapabilities
    # @return [PromptCache, RailsCacheAdapter, nil] Wrapped cache backend
    attr_reader :cache

    # @param cache [PromptCache, RailsCacheAdapter, nil] Prompt cache backend
    # @return [PromptCacheCapabilities]
    def initialize(cache)
      @cache = cache
    end

    # @return [Boolean] Whether prompt caching is enabled
    def enabled?
      !cache.nil?
    end

    # @return [String] Backend identifier used in public stats/events
    def backend_name
      return CacheBackend::DISABLED unless cache
      return CacheBackend::RAILS if cache.is_a?(RailsCacheAdapter)
      return CacheBackend::MEMORY if cache.is_a?(PromptCache)

      cache.class.name
    end

    # @return [Boolean] Whether this backend uses generated storage keys
    def generated_storage_key?
      cache.is_a?(PromptCache) || cache.is_a?(RailsCacheAdapter)
    end

    # @return [Boolean] Whether stale-while-revalidate is available
    def swr?
      cache.respond_to?(:swr_enabled?) && cache.swr_enabled?
    end

    # @return [Boolean] Whether fetch-with-lock is available
    def distributed_lock?
      cache.respond_to?(:fetch_with_lock)
    end

    # @param logical_key [String] Stable logical cache key
    # @param name [String] Prompt name
    # @return [String] Backend storage key
    def storage_key(logical_key, name:)
      return logical_key unless generated_storage_key?

      cache.storage_key(logical_key, name: name)
    end

    # @param key [String] Storage key
    # @return [Object, nil] Cached value
    def get(key)
      cache&.get(key)
    end

    # @param key [String] Storage key
    # @return [Object, nil] Raw cache entry if supported
    def entry(key)
      return nil unless cache.respond_to?(:entry)

      cache.entry(key)
    end

    # @param key [String] Storage key
    # @param value [Object] Value to cache
    # @param ttl [Integer, nil] Optional TTL override
    # @return [Object, nil] Cached value
    def set(key, value, ttl: nil)
      return nil unless cache
      return cache.set(key, value) if ttl.nil?

      cache.set(key, value, ttl: ttl)
    end

    # @param key [String] Storage key
    # @return [Boolean] Whether the key was removed
    def delete(key)
      cache&.delete(key) || false
    end

    # @param name [String] Prompt name
    # @return [Integer, nil] New name generation
    def invalidate_name(name)
      cache&.invalidate_name(name)
    end

    # @return [Integer, nil] New global generation
    def clear_logically
      cache&.clear_logically
    end

    # @return [Hash] Prompt cache stats
    def stats
      return disabled_stats unless cache

      cache.stats
    end

    # @return [Boolean] true when the backend validates successfully
    # @raise [ConfigurationError] if backend validation fails
    # rubocop:disable Naming/PredicateMethod
    def validate!
      cache.validate! if cache.respond_to?(:validate!)
      true
    end
    # rubocop:enable Naming/PredicateMethod

    # @return [void]
    def shutdown
      cache.shutdown if cache.respond_to?(:shutdown)
    end

    # @param key [String] Storage key
    # @param ttl [Integer, nil] Optional TTL override
    # @param on_success [#call, nil] Success callback
    # @param on_failure [#call, nil] Failure callback
    # @yieldreturn [Object] Fresh value
    # @return [Boolean] Whether a refresh was scheduled
    def refresh_async(key, ttl: nil, on_success: nil, on_failure: nil, &)
      return false unless cache.respond_to?(:refresh_async)

      cache.refresh_async(key, ttl: ttl, on_success: on_success, on_failure: on_failure, &)
    end

    # @param key [String] Storage key
    # @param value [Object] Value to cache
    # @param ttl [Integer, nil] Optional TTL override
    # @return [Object, nil] Cached value
    def write_with_stale_while_revalidate(key, value, ttl: nil)
      return nil unless cache.respond_to?(:write_with_stale_while_revalidate)

      cache.write_with_stale_while_revalidate(key, value, ttl: ttl)
    end

    # @param key [String] Storage key
    # @param ttl [Integer, nil] Optional TTL override
    # @yieldreturn [Object] Fresh value
    # @return [Object] Cached or freshly fetched value
    def fetch_with_lock(key, ttl: nil, &)
      return cache.fetch_with_lock(key, &) if ttl.nil?

      cache.fetch_with_lock(key, ttl: ttl, &)
    end

    # @param key [String] Storage key
    # @yieldreturn [Object] Fresh value
    # @return [Object] Cached, stale, or freshly fetched value
    def fetch_with_stale_while_revalidate(key, &)
      cache.fetch_with_stale_while_revalidate(key, &)
    end

    private

    def disabled_stats
      {
        backend: CacheBackend::DISABLED,
        enabled: false,
        current_generation_entries: nil,
        orphaned_entries: nil,
        total_entries: nil,
        unsupported_counts: CacheBackend::UNSUPPORTED_COUNT_KEYS
      }
    end
  end
end
