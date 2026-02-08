# frozen_string_literal: true

module Langfuse
  # Cache warming utility for pre-loading prompts into cache
  #
  # Useful for deployment scenarios where you want to warm the cache
  # before serving traffic, preventing cold-start API calls.
  #
  # @example Warm cache with specific prompts
  #   warmer = Langfuse::CacheWarmer.new
  #   results = warmer.warm(['greeting', 'conversation', 'rag-pipeline'])
  #   puts "Cached #{results[:success].size} prompts"
  #
  # @example Warm cache with error handling
  #   warmer = Langfuse::CacheWarmer.new(client: my_client)
  #   results = warmer.warm(['greeting', 'conversation'])
  #
  #   results[:failed].each do |failure|
  #     logger.warn "Failed to cache #{failure[:name]}: #{failure[:error]}"
  #   end
  #
  class CacheWarmer
    # @return [Client] Langfuse client used for fetching prompts
    attr_reader :client

    # Initialize a new cache warmer
    #
    # @param client [Client, nil] Optional Langfuse client (defaults to global client)
    def initialize(client: nil)
      @client = client || Langfuse.client
    end

    # Warm the cache with specified prompts
    #
    # Fetches each prompt and populates the cache. This is idempotent -
    # safe to call multiple times.
    #
    # @param prompt_names [Array<String>] List of prompt names to cache
    # @param versions [Hash<String, Integer>] Optional version numbers per prompt
    # @param labels [Hash<String, String>] Optional labels per prompt
    # @return [Hash] Results with :success and :failed arrays
    #
    # @example Basic warming
    #   results = warmer.warm(['greeting', 'conversation'])
    #   # => { success: ['greeting', 'conversation'], failed: [] }
    #
    # @example With specific versions
    #   results = warmer.warm(
    #     ['greeting', 'conversation'],
    #     versions: { 'greeting' => 2, 'conversation' => 1 }
    #   )
    #
    # @example With labels
    #   results = warmer.warm(
    #     ['greeting', 'conversation'],
    #     labels: { 'greeting' => 'production' }
    #   )
    def warm(prompt_names, versions: {}, labels: {})
      results = { success: [], failed: [] }

      prompt_names.each do |name|
        warm_single_prompt(name, results, versions, labels)
      end

      results
    end

    # Warm the cache with all prompts (auto-discovery)
    #
    # Automatically discovers all prompts in your Langfuse project via
    # the list_prompts API and warms the cache with all of them.
    # By default, fetches prompts with the "production" label.
    # Useful for deployment scenarios where you want to ensure all prompts
    # are cached without manually specifying them.
    #
    # @param default_label [String, nil] Label to use for all prompts (default: "production")
    # @param versions [Hash<String, Integer>] Optional version numbers per prompt
    # @param labels [Hash<String, String>] Optional labels per specific prompts (overrides default_label)
    # @return [Hash] Results with :success and :failed arrays
    #
    # @example Auto-discover and warm all prompts with "production" label
    #   results = warmer.warm_all
    #   puts "Cached #{results[:success].size} prompts"
    #
    # @example Warm with a different default label
    #   results = warmer.warm_all(default_label: "staging")
    #
    # @example Warm without any label (latest versions)
    #   results = warmer.warm_all(default_label: nil)
    #
    # @example With specific versions for some prompts
    #   results = warmer.warm_all(versions: { 'greeting' => 2 })
    #
    # @example Override label for specific prompts
    #   results = warmer.warm_all(
    #     default_label: "production",
    #     labels: { 'greeting' => 'staging' }  # Use staging for this one
    #   )
    def warm_all(default_label: "production", versions: {}, labels: {})
      prompt_list = client.list_prompts
      prompt_names = prompt_list.map { |p| p["name"] }.uniq

      # Build labels hash: apply default_label to all prompts, then merge overrides
      # BUT: if a version is specified for a prompt, don't apply a label (version takes precedence)
      final_labels = {}
      if default_label
        prompt_names.each do |name|
          # Only apply default label if no version specified for this prompt
          final_labels[name] = default_label unless versions[name]
        end
      end
      final_labels.merge!(labels) # Specific label overrides win

      warm(prompt_names, versions: versions, labels: final_labels)
    end

    # Warm the cache and raise on any failures
    #
    # Same as #warm but raises an error if any prompts fail to cache.
    # Useful when you want to abort deployment if cache warming fails.
    #
    # @param prompt_names [Array<String>] List of prompt names to cache
    # @param versions [Hash<String, Integer>] Optional version numbers per prompt
    # @param labels [Hash<String, String>] Optional labels per prompt
    # @return [Hash] Results with :success array
    # @raise [CacheWarmingError] if any prompts fail to cache
    #
    # @example
    #   begin
    #     warmer.warm!(['greeting', 'conversation'])
    #   rescue Langfuse::CacheWarmingError => e
    #     abort "Cache warming failed: #{e.message}"
    #   end
    def warm!(prompt_names, versions: {}, labels: {})
      results = warm(prompt_names, versions: versions, labels: labels)

      if results[:failed].any?
        failed_names = results[:failed].map { |f| f[:name] }.join(", ")
        raise CacheWarmingError, "Failed to cache prompts: #{failed_names}"
      end

      results
    end

    # Check if cache warming is enabled
    #
    # Returns false if caching is disabled (cache_ttl = 0)
    #
    # @return [Boolean]
    def cache_enabled?
      cache = client.api_client.cache
      return false if cache.nil?

      cache.ttl&.positive? || false
    end

    # Get cache statistics (if supported by backend)
    #
    # @return [Hash, nil] Cache stats or nil if not supported
    def cache_stats
      cache = client.api_client.cache
      return nil unless cache

      stats = {}
      stats[:backend] = cache.class.name.split("::").last
      stats[:ttl] = cache.ttl if cache.respond_to?(:ttl)
      stats[:size] = cache.size if cache.respond_to?(:size)
      stats[:max_size] = cache.max_size if cache.respond_to?(:max_size)
      stats
    end

    private

    # Warm a single prompt and update results
    #
    # @param name [String] Prompt name
    # @param results [Hash] Results hash to update
    # @param versions [Hash] Version numbers per prompt
    # @param labels [Hash] Labels per prompt
    # @return [void]
    def warm_single_prompt(name, results, versions, labels)
      options = build_prompt_options(name, versions, labels)

      client.get_prompt(name, **options)
      results[:success] << name
    rescue NotFoundError
      record_failure(results, name, "Not found")
    rescue UnauthorizedError
      record_failure(results, name, "Unauthorized")
    rescue ApiError, StandardError => e
      record_failure(results, name, e.message)
    end

    # Build options hash for get_prompt
    #
    # @param name [String] Prompt name
    # @param versions [Hash] Version numbers per prompt
    # @param labels [Hash] Labels per prompt
    # @return [Hash] Options hash
    def build_prompt_options(name, versions, labels)
      options = {}
      options[:version] = versions[name] if versions[name]
      options[:label] = labels[name] if labels[name]
      options
    end

    # Record a prompt failure
    #
    # @param results [Hash] Results hash to update
    # @param name [String] Prompt name
    # @param error [String] Error message
    # @return [void]
    def record_failure(results, name, error)
      results[:failed] << { name: name, error: error }
    end
  end

  # Error raised when cache warming fails with warm!
  class CacheWarmingError < Error; end
end
