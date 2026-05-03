# frozen_string_literal: true

module Langfuse
  # Public metadata returned by prompt fetch operations.
  class PromptFetchResult
    # @return [Object] Prompt data or prompt client returned by the fetch
    attr_reader :prompt

    # @return [String] Stable logical cache identity
    attr_reader :logical_key

    # @return [String] Generated backend key for the current cache generation
    attr_reader :storage_key

    # @return [Symbol] Cache status (:hit, :miss, :stale, :refresh, :bypass, :disabled)
    attr_reader :cache_status

    # @return [Symbol] Source of the returned prompt (:cache, :api, :fallback)
    attr_reader :source

    # @return [String] Prompt name
    attr_reader :name

    # @return [Integer, nil] Prompt version
    attr_reader :version

    # @return [String, nil] Prompt label
    attr_reader :label

    # @param prompt [Object] Prompt data or prompt client
    # @param logical_key [String] Stable logical cache identity
    # @param storage_key [String] Generated backend key
    # @param cache_status [Symbol] Cache status
    # @param source [Symbol] Prompt source
    # @param name [String] Prompt name
    # @param version [Integer, nil] Prompt version
    # @param label [String, nil] Prompt label
    # @return [PromptFetchResult]
    # rubocop:disable Metrics/ParameterLists
    def initialize(prompt:, logical_key:, storage_key:, cache_status:, source:, name:, version: nil, label: nil)
      @prompt = prompt
      @logical_key = logical_key
      @storage_key = storage_key
      @cache_status = cache_status.to_sym
      @source = source.to_sym
      @name = name
      @version = version
      @label = label
    end
    # rubocop:enable Metrics/ParameterLists

    # Compatibility alias for callers that already use "cache key" language.
    #
    # @return [String] Stable logical cache identity
    def cache_key
      logical_key
    end

    # @return [Boolean] Whether this result used caller-provided fallback content
    def fallback?
      source == :fallback || (prompt.respond_to?(:is_fallback) && prompt.is_fallback)
    end

    # @return [Hash] Result metadata as a hash
    def to_h
      {
        logical_key: logical_key,
        storage_key: storage_key,
        cache_status: cache_status,
        source: source,
        name: name,
        version: version,
        label: label,
        fallback: fallback?
      }
    end
  end

  # Public key inspection result for prompt cache operations.
  class PromptCacheKey
    # @return [String] Prompt name
    attr_reader :name

    # @return [Integer, nil] Prompt version
    attr_reader :version

    # @return [String, nil] Prompt label
    attr_reader :label

    # @return [String] Stable logical cache identity
    attr_reader :logical_key

    # @return [String] Generated backend key for the current cache generation
    attr_reader :storage_key

    # @param name [String] Prompt name
    # @param logical_key [String] Stable logical cache identity
    # @param storage_key [String] Generated backend key
    # @param version [Integer, nil] Prompt version
    # @param label [String, nil] Prompt label
    # @return [PromptCacheKey]
    def initialize(name:, logical_key:, storage_key:, version: nil, label: nil)
      @name = name
      @version = version
      @label = label
      @logical_key = logical_key
      @storage_key = storage_key
    end

    # @return [Hash] Cache key data as a hash
    def to_h
      {
        name: name,
        version: version,
        label: label,
        logical_key: logical_key,
        storage_key: storage_key
      }
    end
  end
end
