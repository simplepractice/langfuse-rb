# frozen_string_literal: true

require_relative "prompt_fetch_result"
require_relative "prompt_cache_events"

module Langfuse
  # Coordinates prompt fetch/cache behavior between the API transport and the
  # configured cache backend. Both supported backends ({PromptCache} and
  # {RailsCacheAdapter}) provide the full cache + SWR surface; only
  # {RailsCacheAdapter} adds distributed-lock fetch, which is the one branch
  # the dispatch needs to make.
  #
  # @api private
  class PromptCacheCoordinator # rubocop:disable Metrics/ClassLength
    # @param cache [PromptCache, RailsCacheAdapter, nil] Configured cache backend
    # @param event_emitter [#emit_prompt_cache_event] Emitter for cache events
    # @param fetch_prompt [#call] Callable that fetches prompt data from the API
    # @return [PromptCacheCoordinator]
    def initialize(cache:, event_emitter:, fetch_prompt:)
      @cache = cache
      @event_emitter = event_emitter
      @fetch_prompt = fetch_prompt
      @backend_name = compute_backend_name
    end

    # @return [String] Backend identifier reported in events and stats
    attr_reader :backend_name

    # Fetch a prompt and include cache metadata.
    #
    # @param name [String] Prompt name
    # @param version [Integer, nil] Optional prompt version
    # @param label [String, nil] Optional prompt label
    # @param cache_ttl [Integer, nil] Optional TTL override (0 forces a bypass)
    # @return [PromptFetchResult] Prompt data plus cache metadata
    def get_prompt_result(name, version: nil, label: nil, cache_ttl: nil)
      validate_fetch_options!(version, label, cache_ttl)
      key = prompt_cache_key(name, version: version, label: label)

      return fetch_uncached(key, CacheStatus::DISABLED) if @cache.nil?
      return fetch_uncached(key, CacheStatus::BYPASS) if cache_ttl&.zero?

      fetch_cached(key, cache_ttl)
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
      key = prompt_cache_key(name, version: version, label: label)

      emit(:refresh_start) { event_payload(key, CacheStatus::REFRESH, CacheSource::API) }
      prompt_data = @fetch_prompt.call(name, version: version, label: label)
      write_through(key, prompt_data, cache_ttl, status: CacheStatus::REFRESH) if @cache && !cache_ttl&.zero?
      status = refresh_status(cache_ttl)
      emit(:refresh_success) { event_payload(key, status, CacheSource::API) }
      build_result(key, prompt_data, status, CacheSource::API)
    rescue StandardError => e
      emit(:refresh_failure) do
        event_payload(key, CacheStatus::REFRESH, CacheSource::API,
                      error_class: e.class.name, error_message: e.message)
      end
      raise
    end

    # Inspect the logical and generated cache keys for a prompt.
    #
    # @param name [String] Prompt name
    # @param version [Integer, nil] Optional prompt version
    # @param label [String, nil] Optional prompt label
    # @return [PromptCacheKey] Logical and generated cache keys
    def prompt_cache_key(name, version: nil, label: nil)
      raise ArgumentError, "Cannot specify both version and label" if version && label

      logical_key = PromptCache.build_key(name, version: version, label: label)
      storage_key = @cache ? @cache.storage_key(logical_key, name: name) : logical_key
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
      deleted = @cache ? @cache.delete(key.storage_key) : false
      emit(:delete) { event_payload(key, CacheStatus::MISS, CacheSource::CACHE, deleted: deleted) }
      emit(:invalidate) { event_payload(key, CacheStatus::MISS, CacheSource::CACHE, scope: :exact) }
      key
    end

    # Invalidate all cached variants for one prompt name.
    #
    # @param name [String] Prompt name
    # @return [Integer, nil] New generation, or nil when caching is disabled
    def invalidate_prompt_cache_by_name(name)
      emit_name_invalidation(name, mutation: false)
    end

    # Invalidate after prompt mutation (create/update). Distinct from manual
    # invalidation so observers can tell the two apart.
    #
    # @param name [String] Prompt name
    # @return [Integer, nil] New generation
    def invalidate_after_mutation(name)
      emit_name_invalidation(name, mutation: true)
    end

    # Logically clear the entire prompt cache namespace.
    #
    # @return [Integer, nil] New global generation, or nil when caching is disabled
    def clear_prompt_cache
      generation = @cache&.clear_logically
      emit(:clear, backend: @backend_name, generation: generation)
      generation
    end

    # @return [Hash] Prompt cache statistics
    def prompt_cache_stats
      @cache ? @cache.stats : disabled_stats
    end

    private

    def validate_fetch_options!(version, label, cache_ttl)
      raise ArgumentError, "Cannot specify both version and label" if version && label
      return if cache_ttl.nil?
      raise ArgumentError, "cache_ttl must be a non-negative Integer" unless cache_ttl.is_a?(Integer)
      raise ArgumentError, "cache_ttl must be non-negative" if cache_ttl.negative?
    end

    def fetch_uncached(key, status)
      prompt_data = @fetch_prompt.call(key.name, version: key.version, label: key.label)
      build_result(key, prompt_data, status, CacheSource::API)
    end

    # Single dispatch: SWR > distributed lock > simple get/set.
    def fetch_cached(key, cache_ttl)
      return fetch_with_swr(key, cache_ttl) if @cache.swr_enabled?
      return fetch_with_lock(key, cache_ttl) if @cache.is_a?(RailsCacheAdapter)

      cached = @cache.get(key.storage_key)
      return cache_hit(key, cached) if cached

      fetch_and_cache(key, cache_ttl, swr: false)
    end

    def fetch_with_swr(key, cache_ttl)
      entry = @cache.entry(key.storage_key)
      return cache_hit(key, entry.data) if entry.respond_to?(:fresh?) && entry.fresh?

      if entry.respond_to?(:stale?) && entry.stale?
        emit(:stale_serve) { event_payload(key, CacheStatus::STALE, CacheSource::CACHE) }
        schedule_refresh(key, cache_ttl)
        return build_result(key, entry.data, CacheStatus::STALE, CacheSource::CACHE)
      end

      fetch_and_cache(key, cache_ttl, swr: true)
    end

    def fetch_with_lock(key, cache_ttl)
      cached = @cache.get(key.storage_key)
      return cache_hit(key, cached) if cached

      emit(:miss) { event_payload(key, CacheStatus::MISS, CacheSource::API) }
      fetched = false
      prompt_data = @cache.fetch_with_lock(key.storage_key, ttl: cache_ttl) do
        fetched = true
        @fetch_prompt.call(key.name, version: key.version, label: key.label)
      end
      emit(:write) { event_payload(key, CacheStatus::MISS, CacheSource::API) } if fetched
      status = fetched ? CacheStatus::MISS : CacheStatus::HIT
      source = fetched ? CacheSource::API : CacheSource::CACHE
      build_result(key, prompt_data, status, source)
    end

    def fetch_and_cache(key, cache_ttl, swr:)
      emit(:miss) { event_payload(key, CacheStatus::MISS, CacheSource::API) }
      prompt_data = @fetch_prompt.call(key.name, version: key.version, label: key.label)
      write_through(key, prompt_data, cache_ttl, swr: swr)
      build_result(key, prompt_data, CacheStatus::MISS, CacheSource::API)
    end

    def write_through(key, prompt_data, cache_ttl, swr: false, status: CacheStatus::MISS)
      if swr
        @cache.write_with_stale_while_revalidate(key.storage_key, prompt_data, ttl: cache_ttl)
      else
        @cache.set(key.storage_key, prompt_data, ttl: cache_ttl)
      end
      emit(:write) { event_payload(key, status, CacheSource::API) }
    end

    def cache_hit(key, prompt_data)
      emit(:hit) { event_payload(key, CacheStatus::HIT, CacheSource::CACHE) }
      build_result(key, prompt_data, CacheStatus::HIT, CacheSource::CACHE)
    end

    def schedule_refresh(key, cache_ttl)
      scheduled = @cache.refresh_async(
        key.storage_key,
        ttl: cache_ttl,
        on_success: ->(_value) { emit_refresh_success(key) },
        on_failure: ->(error) { emit_refresh_failure(key, error) }
      ) { @fetch_prompt.call(key.name, version: key.version, label: key.label) }
      emit(:refresh_start) { event_payload(key, CacheStatus::STALE, CacheSource::CACHE) } if scheduled
    end

    def emit_refresh_success(key)
      emit(:refresh_success) { event_payload(key, CacheStatus::REFRESH, CacheSource::API) }
      emit(:write) { event_payload(key, CacheStatus::REFRESH, CacheSource::API) }
    end

    def emit_refresh_failure(key, error)
      emit(:refresh_failure) do
        event_payload(key, CacheStatus::STALE, CacheSource::CACHE,
                      error_class: error.class.name, error_message: error.message)
      end
    end

    def emit_name_invalidation(name, mutation:)
      generation = @cache&.invalidate_name(name)
      payload = { name: name, backend: @backend_name, generation: generation, scope: :name }
      payload[:mutation] = true if mutation
      emit(:invalidate, payload)
      generation
    end

    def refresh_status(cache_ttl)
      return CacheStatus::DISABLED unless @cache
      return CacheStatus::BYPASS if cache_ttl&.zero?

      CacheStatus::REFRESH
    end

    def build_result(key, prompt_data, status, source)
      PromptFetchResult.new(
        prompt: prompt_data,
        logical_key: key.logical_key,
        storage_key: key.storage_key,
        cache_status: status,
        source: source,
        name: prompt_data["name"] || key.name,
        version: prompt_data["version"] || key.version,
        label: key.resolved_label
      )
    end

    def emit(event, payload = nil, &)
      @event_emitter.emit_prompt_cache_event(event, payload, &)
    end

    def event_payload(key, cache_status, source, **extra)
      PromptCacheEvents.build_payload(
        key,
        cache_status: cache_status,
        source: source,
        backend: @backend_name,
        extra: extra
      )
    end

    def compute_backend_name
      return CacheBackend::DISABLED unless @cache
      return CacheBackend::RAILS if @cache.is_a?(RailsCacheAdapter)
      return CacheBackend::MEMORY if @cache.is_a?(PromptCache)

      @cache.class.name
    end

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
