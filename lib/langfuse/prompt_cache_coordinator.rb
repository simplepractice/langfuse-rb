# frozen_string_literal: true

require_relative "prompt_fetch_result"

module Langfuse
  # Coordinates prompt fetch/cache behavior independently from HTTP transport.
  #
  # @api private
  class PromptCacheCoordinator # rubocop:disable Metrics/ClassLength
    # Bundles the resolved cache key with the per-call TTL override.
    FetchOptions = Struct.new(:key, :cache_ttl, keyword_init: true) do
      # @return [String] Prompt name
      def name = key.name

      # @return [Integer, nil] Prompt version
      def version = key.version

      # @return [String, nil] Prompt label
      def label = key.label
    end

    # @param cache_capabilities [PromptCacheCapabilities] Cache capability wrapper
    # @param event_emitter [#emit_prompt_cache_event] Event emitter
    # @param fetch_prompt [#call] Callable that fetches prompt data from transport
    # @return [PromptCacheCoordinator]
    def initialize(cache_capabilities:, event_emitter:, fetch_prompt:)
      @cache = cache_capabilities
      @event_emitter = event_emitter
      @fetch_prompt = fetch_prompt
    end

    # Fetch a prompt and include cache metadata.
    #
    # @param name [String] Prompt name
    # @param version [Integer, nil] Optional prompt version
    # @param label [String, nil] Optional prompt label
    # @param cache_ttl [Integer, nil] Optional TTL override
    # @return [PromptFetchResult] Prompt data plus cache metadata
    def get_prompt_result(name, version: nil, label: nil, cache_ttl: nil)
      validate_fetch_options!(version, label, cache_ttl)

      options = build_fetch_options(name, version: version, label: label, cache_ttl: cache_ttl)
      return fetch_uncached_prompt_result(options, CacheStatus::DISABLED) unless cache.enabled?
      return fetch_uncached_prompt_result(options, CacheStatus::BYPASS) if cache_ttl&.zero?

      fetch_cached_prompt_result(options)
    end

    # Refresh a prompt from the API, optionally writing through to cache.
    #
    # @param name [String] Prompt name
    # @param version [Integer, nil] Optional prompt version
    # @param label [String, nil] Optional prompt label
    # @param cache_ttl [Integer, nil] Optional TTL override
    # @return [PromptFetchResult] Prompt data plus cache metadata
    def refresh_prompt(name, version: nil, label: nil, cache_ttl: nil)
      validate_fetch_options!(version, label, cache_ttl)
      refresh_prompt_result(build_fetch_options(name, version: version, label: label, cache_ttl: cache_ttl))
    end

    # Inspect the logical and generated cache keys for a prompt.
    #
    # @param name [String] Prompt name
    # @param version [Integer, nil] Optional prompt version
    # @param label [String, nil] Optional prompt label
    # @return [PromptCacheKey] Logical and generated cache key
    def prompt_cache_key(name, version: nil, label: nil)
      raise ArgumentError, "Cannot specify both version and label" if version && label

      logical_key = PromptCache.build_key(name, version: version, label: label)
      storage_key = cache.storage_key(logical_key, name: name)
      PromptCacheKey.new(name: name, version: version, label: label, logical_key: logical_key, storage_key: storage_key)
    end

    # Invalidate one exact logical prompt cache key.
    #
    # @param name [String] Prompt name
    # @param version [Integer, nil] Optional prompt version
    # @param label [String, nil] Optional prompt label
    # @return [PromptCacheKey] Invalidated key
    def invalidate_prompt_cache(name, version: nil, label: nil)
      key = prompt_cache_key(name, version: version, label: label)
      deleted = cache.delete(key.storage_key)
      emit(:delete) { event_payload(key, CacheStatus::MISS, CacheSource::CACHE, deleted: deleted) }
      emit(:invalidate) { event_payload(key, CacheStatus::MISS, CacheSource::CACHE, scope: :exact) }
      key
    end

    # Invalidate all cached variants for one prompt name.
    #
    # @param name [String] Prompt name
    # @return [Integer, nil] New generation
    def invalidate_prompt_cache_by_name(name)
      emit_name_invalidation(name, mutation: false)
    end

    # Logically clear the whole prompt cache namespace.
    #
    # @return [Integer, nil] New global generation
    def clear_prompt_cache
      generation = cache.clear_logically
      emit(:clear, backend: cache.backend_name, generation: generation)
      generation
    end

    # @return [Hash] Prompt cache statistics
    def prompt_cache_stats
      cache.stats
    end

    # Invalidate all variants after prompt mutation.
    #
    # @param name [String] Prompt name
    # @return [Integer, nil] New generation
    def invalidate_after_mutation(name)
      emit_name_invalidation(name, mutation: true)
    end

    private

    attr_reader :cache

    def validate_fetch_options!(version, label, cache_ttl)
      raise ArgumentError, "Cannot specify both version and label" if version && label
      return if cache_ttl.nil?
      raise ArgumentError, "cache_ttl must be a non-negative Integer" unless cache_ttl.is_a?(Integer)
      raise ArgumentError, "cache_ttl must be non-negative" if cache_ttl.negative?
    end

    def build_fetch_options(name, version:, label:, cache_ttl:)
      FetchOptions.new(key: prompt_cache_key(name, version: version, label: label), cache_ttl: cache_ttl)
    end

    def fetch_uncached_prompt_result(options, cache_status)
      prompt_data = fetch_prompt_for_options(options)
      build_prompt_result(options.key, prompt_data, cache_status, CacheSource::API)
    end

    def fetch_cached_prompt_result(options)
      return fetch_swr_prompt_result(options) if cache.swr?

      fetch_non_swr_prompt_result(options)
    end

    def fetch_swr_prompt_result(options)
      unless cache.generated_storage_key?
        prompt_data = cache.fetch_with_stale_while_revalidate(options.key.storage_key) do
          fetch_prompt_for_options(options)
        end
        return cache_hit_prompt_result(options.key, prompt_data)
      end

      result = fetch_swr_cached_prompt_result(options)
      return result if result

      fetch_cache_miss_prompt_result(options, swr_enabled: true, distributed_enabled: false)
    end

    def fetch_non_swr_prompt_result(options)
      distributed_enabled = cache.distributed_lock?

      if !cache.generated_storage_key? && distributed_enabled
        prompt_data = cache.fetch_with_lock(options.key.storage_key) { fetch_prompt_for_options(options) }
        return cache_hit_prompt_result(options.key, prompt_data)
      end

      cached_data = cache.get(options.key.storage_key)
      return cache_hit_prompt_result(options.key, cached_data) if cached_data

      fetch_cache_miss_prompt_result(options, swr_enabled: false, distributed_enabled: distributed_enabled)
    end

    def fetch_swr_cached_prompt_result(options)
      key = options.key
      entry = cache.entry(key.storage_key)
      return nil unless entry.respond_to?(:fresh?)
      return cache_hit_prompt_result(key, entry.data) if entry.fresh?
      return nil unless entry.stale?

      emit(:stale_serve) { event_payload(key, CacheStatus::STALE, CacheSource::CACHE) }
      schedule_prompt_cache_refresh(options)
      build_prompt_result(key, entry.data, CacheStatus::STALE, CacheSource::CACHE)
    end

    def cache_hit_prompt_result(key, prompt_data)
      emit(:hit) { event_payload(key, CacheStatus::HIT, CacheSource::CACHE) }
      build_prompt_result(key, prompt_data, CacheStatus::HIT, CacheSource::CACHE)
    end

    def fetch_cache_miss_prompt_result(options, swr_enabled: false, distributed_enabled: nil)
      emit(:miss) { event_payload(options.key, CacheStatus::MISS, CacheSource::API) }
      distributed_enabled = cache.distributed_lock? if distributed_enabled.nil?

      if !swr_enabled && distributed_enabled
        fetch_cache_miss_with_lock(options)
      else
        fetch_cache_miss_directly(options, swr_enabled: swr_enabled)
      end
    end

    def fetch_cache_miss_with_lock(options)
      key = options.key
      fetched = false
      prompt_data = cache.fetch_with_lock(key.storage_key, ttl: options.cache_ttl) do
        fetched = true
        fetch_prompt_for_options(options)
      end
      emit(:write) { event_payload(key, CacheStatus::MISS, CacheSource::API) } if fetched
      status = fetched ? CacheStatus::MISS : CacheStatus::HIT
      source = fetched ? CacheSource::API : CacheSource::CACHE
      build_prompt_result(key, prompt_data, status, source)
    end

    def fetch_cache_miss_directly(options, swr_enabled: false)
      prompt_data = fetch_prompt_for_options(options)
      write_prompt_cache(options.key, prompt_data, options.cache_ttl, swr_enabled: swr_enabled)
      build_prompt_result(options.key, prompt_data, CacheStatus::MISS, CacheSource::API)
    end

    def refresh_prompt_result(options)
      key = options.key
      emit(:refresh_start) { event_payload(key, CacheStatus::REFRESH, CacheSource::API) }
      prompt_data = fetch_prompt_for_options(options)
      write_refresh_prompt_cache(key, prompt_data, options.cache_ttl)
      status = refresh_cache_status(options.cache_ttl)
      emit(:refresh_success) { event_payload(key, status, CacheSource::API) }
      build_prompt_result(key, prompt_data, status, CacheSource::API)
    rescue StandardError => e
      emit(:refresh_failure) do
        event_payload(key, CacheStatus::REFRESH, CacheSource::API,
                      error_class: e.class.name, error_message: e.message)
      end
      raise
    end

    def schedule_prompt_cache_refresh(options)
      key = options.key
      scheduled = cache.refresh_async(
        key.storage_key,
        ttl: options.cache_ttl,
        on_success: ->(_value) { emit_refresh_success_events(key) },
        on_failure: ->(error) { emit_refresh_failure_event(key, error) }
      ) { fetch_prompt_for_options(options) }
      return unless scheduled

      emit(:refresh_start) { event_payload(key, CacheStatus::STALE, CacheSource::CACHE) }
    end

    def fetch_prompt_for_options(options)
      @fetch_prompt.call(options.name, version: options.version, label: options.label)
    end

    def emit_refresh_success_events(key)
      emit(:refresh_success) { event_payload(key, CacheStatus::REFRESH, CacheSource::API) }
      emit(:write) { event_payload(key, CacheStatus::REFRESH, CacheSource::API) }
    end

    def emit_refresh_failure_event(key, error)
      emit(:refresh_failure) do
        event_payload(key, CacheStatus::STALE, CacheSource::CACHE,
                      error_class: error.class.name, error_message: error.message)
      end
    end

    def write_refresh_prompt_cache(key, prompt_data, cache_ttl)
      return unless cache.enabled?
      return if cache_ttl&.zero?

      write_prompt_cache(key, prompt_data, cache_ttl, cache_status: CacheStatus::REFRESH, swr_enabled: cache.swr?)
    end

    def write_prompt_cache(key, prompt_data, cache_ttl, cache_status: CacheStatus::MISS, swr_enabled: false)
      if swr_enabled
        cache.write_with_stale_while_revalidate(key.storage_key, prompt_data, ttl: cache_ttl)
      else
        cache.set(key.storage_key, prompt_data, ttl: cache_ttl)
      end
      emit(:write) { event_payload(key, cache_status, CacheSource::API) }
    end

    def refresh_cache_status(cache_ttl)
      return CacheStatus::DISABLED unless cache.enabled?
      return CacheStatus::BYPASS if cache_ttl&.zero?

      CacheStatus::REFRESH
    end

    def build_prompt_result(key, prompt_data, cache_status, source)
      PromptFetchResult.new(
        prompt: prompt_data,
        logical_key: key.logical_key,
        storage_key: key.storage_key,
        cache_status: cache_status,
        source: source,
        name: prompt_data["name"] || key.name,
        version: prompt_data["version"] || key.version,
        label: key.resolved_label
      )
    end

    def emit_name_invalidation(name, mutation:)
      generation = cache.invalidate_name(name)
      payload = { name: name, backend: cache.backend_name, generation: generation, scope: :name }
      payload[:mutation] = true if mutation
      emit(:invalidate, payload)
      generation
    end

    def emit(event, payload = nil, &)
      @event_emitter.emit_prompt_cache_event(event, payload, &)
    end

    def event_payload(key, cache_status, source, extra = {})
      {
        name: key.name,
        version: key.version,
        label: key.resolved_label,
        logical_key: key.logical_key,
        storage_key: key.storage_key,
        backend: cache.backend_name,
        cache_status: cache_status,
        source: source
      }.merge(extra)
    end
  end
end
