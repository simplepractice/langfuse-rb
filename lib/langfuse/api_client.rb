# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "base64"
require "json"
require "uri"
require_relative "prompt_fetch_result"
require_relative "prompt_cache_capabilities"
require_relative "prompt_cache_coordinator"
require_relative "resources/batches"
require_relative "resources/datasets"
require_relative "resources/prompts"
require_relative "resources/traces"

module Langfuse
  # HTTP client for Langfuse API
  #
  # Handles authentication, connection management, and HTTP requests
  # to the Langfuse REST API.
  #
  # @example
  #   api_client = Langfuse::ApiClient.new(
  #     public_key: "pk_...",
  #     secret_key: "sk_...",
  #     base_url: "https://cloud.langfuse.com",
  #     timeout: 5,
  #     logger: Logger.new($stdout)
  #   )
  #
  class ApiClient # rubocop:disable Metrics/ClassLength
    include PromptCacheEvents

    PromptFetchOptions = PromptCacheCoordinator::FetchOptions

    # @return [String] Langfuse public API key
    attr_reader :public_key

    # @return [String] Langfuse secret API key
    attr_reader :secret_key

    # @return [String] Base URL for Langfuse API
    attr_reader :base_url

    # @return [Integer] HTTP request timeout in seconds
    attr_reader :timeout

    # @return [Logger] Logger instance for debugging
    attr_reader :logger

    # @return [PromptCache, RailsCacheAdapter, nil] Optional cache for prompt responses
    attr_reader :cache

    # Initialize a new API client
    #
    # @param public_key [String] Langfuse public API key
    # @param secret_key [String] Langfuse secret API key
    # @param base_url [String] Base URL for Langfuse API
    # @param timeout [Integer] HTTP request timeout in seconds
    # @param logger [Logger] Logger instance for debugging
    # @param cache [PromptCache, RailsCacheAdapter, nil] Optional cache for prompt responses
    # @param cache_observer [#call, nil] Optional observer for prompt cache events
    # @return [ApiClient]
    # rubocop:disable Metrics/ParameterLists
    def initialize(public_key:, secret_key:, base_url:, timeout: 5, logger: nil, cache: nil, cache_observer: nil)
      @public_key = public_key
      @secret_key = secret_key
      @base_url = base_url
      @timeout = timeout
      @logger = logger || Logger.new($stdout, level: Logger::WARN)
      @cache = cache
      @cache_capabilities = PromptCacheCapabilities.new(cache)
      @cache_backend_name = @cache_capabilities.backend_name
      setup_prompt_cache_events(cache_observer: cache_observer)
      @prompt_cache_coordinator = PromptCacheCoordinator.new(
        cache_capabilities: @cache_capabilities,
        event_emitter: self,
        fetch_prompt: ->(name, version:, label:) { fetch_prompt_from_api(name, version: version, label: label) }
      )
      initialize_resources
    end
    # rubocop:enable Metrics/ParameterLists

    # Get a Faraday connection
    #
    # @param timeout [Integer, nil] Optional custom timeout for this connection
    # @return [Faraday::Connection]
    def connection(timeout: nil)
      if timeout
        # Create dedicated connection for custom timeout
        # to avoid mutating shared connection
        build_connection(timeout: timeout)
      else
        @connection ||= build_connection
      end
    end

    # List all prompts in the Langfuse project
    #
    # Fetches a list of all prompt names available in your project.
    # Note: This returns metadata only, not full prompt content.
    #
    # @param page [Integer, nil] Optional page number for pagination
    # @param limit [Integer, nil] Optional limit per page (default: API default)
    # @return [Array<Hash>] Array of prompt metadata hashes
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   prompts = api_client.list_prompts
    #   prompts.each do |prompt|
    #     puts "#{prompt['name']} (v#{prompt['version']})"
    #   end
    def list_prompts(page: nil, limit: nil)
      @prompt_resource.list(page: page, limit: limit)
    end

    # Fetch a prompt from the Langfuse API
    #
    # Checks cache first if caching is enabled. On cache miss, fetches from API
    # and stores in cache. When using Rails.cache backend, uses distributed lock
    # to prevent cache stampedes.
    #
    # @param name [String] The name of the prompt
    # @param version [Integer, nil] Optional specific version number
    # @param label [String, nil] Optional label (e.g., "production", "latest")
    # @param cache_ttl [Integer, nil] Optional TTL override for this fetch
    # @return [Hash] The prompt data
    # @raise [ArgumentError] if both version and label are provided
    # @raise [NotFoundError] if the prompt is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def get_prompt(name, version: nil, label: nil, cache_ttl: nil)
      get_prompt_result(name, version: version, label: label, cache_ttl: cache_ttl).prompt
    end

    # Fetch a prompt and include cache metadata.
    #
    # @param name [String] The name of the prompt
    # @param version [Integer, nil] Optional specific version number
    # @param label [String, nil] Optional label (e.g., "production", "latest")
    # @param cache_ttl [Integer, nil] Optional TTL override for this fetch
    # @return [PromptFetchResult] Prompt data plus cache metadata
    # @raise [ArgumentError] if both version and label are provided
    # @raise [ArgumentError] if cache_ttl is negative
    # @raise [NotFoundError] if the prompt is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def get_prompt_result(name, version: nil, label: nil, cache_ttl: nil)
      @prompt_cache_coordinator.get_prompt_result(name, version: version, label: label, cache_ttl: cache_ttl)
    end

    # Refresh a prompt from the API, optionally writing through to cache.
    #
    # @param name [String] The name of the prompt
    # @param version [Integer, nil] Optional specific version number
    # @param label [String, nil] Optional label
    # @param cache_ttl [Integer, nil] Optional TTL override for this refresh
    # @return [PromptFetchResult] Prompt data plus cache metadata
    # @raise [ArgumentError] if both version and label are provided
    # @raise [ArgumentError] if cache_ttl is negative
    # @raise [NotFoundError] if the prompt is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def refresh_prompt(name, version: nil, label: nil, cache_ttl: nil)
      @prompt_cache_coordinator.refresh_prompt(name, version: version, label: label, cache_ttl: cache_ttl)
    end

    # Inspect the logical and generated cache keys for a prompt.
    #
    # @param name [String] The prompt name
    # @param version [Integer, nil] Optional specific version number
    # @param label [String, nil] Optional label
    # @return [PromptCacheKey] Logical and generated cache keys
    # @raise [ArgumentError] if both version and label are provided
    def prompt_cache_key(name, version: nil, label: nil)
      @prompt_cache_coordinator.prompt_cache_key(name, version: version, label: label)
    end

    # Invalidate one exact logical prompt cache key.
    #
    # @param name [String] The prompt name
    # @param version [Integer, nil] Optional specific version number
    # @param label [String, nil] Optional label
    # @return [PromptCacheKey] The invalidated key
    # @raise [ArgumentError] if both version and label are provided
    def invalidate_prompt_cache(name, version: nil, label: nil)
      @prompt_cache_coordinator.invalidate_prompt_cache(name, version: version, label: label)
    end

    # Invalidate all cached variants for one prompt name.
    #
    # @param name [String] The prompt name
    # @return [Integer, nil] New generation, or nil when cache is disabled
    def invalidate_prompt_cache_by_name(name)
      @prompt_cache_coordinator.invalidate_prompt_cache_by_name(name)
    end

    # Logically clear the whole Langfuse prompt cache namespace.
    #
    # @return [Integer, nil] New global generation, or nil when cache is disabled
    def clear_prompt_cache
      @prompt_cache_coordinator.clear_prompt_cache
    end

    # Return prompt cache statistics.
    #
    # @return [Hash] Cache statistics
    def prompt_cache_stats
      @prompt_cache_coordinator.prompt_cache_stats
    end

    # Validate the configured prompt cache backend.
    #
    # @return [Boolean] true when the configured backend is usable
    # @raise [ConfigurationError] if the backend is invalid
    def validate_prompt_cache_backend!
      @cache_capabilities.validate!
    end

    # Create a new prompt (or new version if prompt with same name exists)
    #
    # @param name [String] The prompt name
    # @param prompt [String, Array<Hash>] The prompt content
    # @param type [String] Prompt type ("text" or "chat")
    # @param config [Hash] Optional configuration (model params, etc.)
    # @param labels [Array<String>] Optional labels (e.g., ["production"])
    # @param tags [Array<String>] Optional tags
    # @param commit_message [String, nil] Optional commit message
    # @return [Hash] The created prompt data
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example Create a text prompt
    #   api_client.create_prompt(
    #     name: "greeting",
    #     prompt: "Hello {{name}}!",
    #     type: "text",
    #     labels: ["production"]
    #   )
    #
    # rubocop:disable Metrics/ParameterLists
    def create_prompt(name:, prompt:, type:, config: {}, labels: [], tags: [], commit_message: nil)
      @prompt_resource.create(
        name: name,
        prompt: prompt,
        type: type,
        config: config,
        labels: labels,
        tags: tags,
        commit_message: commit_message
      )
    end
    # rubocop:enable Metrics/ParameterLists

    # Update labels for an existing prompt version
    #
    # @param name [String] The prompt name
    # @param version [Integer] The version number to update
    # @param labels [Array<String>] New labels (replaces existing). Required.
    # @return [Hash] The updated prompt data
    # @raise [ArgumentError] if labels is not an array
    # @raise [NotFoundError] if the prompt is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example Promote a prompt to production
    #   api_client.update_prompt(
    #     name: "greeting",
    #     version: 2,
    #     labels: ["production"]
    #   )
    def update_prompt(name:, version:, labels:)
      @prompt_resource.update(name: name, version: version, labels: labels)
    end

    # Send a batch of events to the Langfuse ingestion API
    #
    # Sends events (scores, traces, observations) to the ingestion endpoint.
    # Retries transient errors (429, 503, 504, network errors) with exponential backoff.
    # Batch operations are idempotent (events have unique IDs), so retries are safe.
    #
    # @param events [Array<Hash>] Array of event hashes to send
    # @return [void]
    # @raise [ArgumentError] if events is not an Array or is empty
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors after retries exhausted
    #
    # @example
    #   events = [
    #     {
    #       id: SecureRandom.uuid,
    #       type: "score-create",
    #       timestamp: Time.now.iso8601,
    #       body: { name: "quality", value: 0.85, trace_id: "abc123..." }
    #     }
    #   ]
    #   api_client.send_batch(events)
    def send_batch(events)
      @batch_resource.send_batch(events)
    end

    # Create a dataset run item (link a trace to a dataset item within a run)
    #
    # @param dataset_item_id [String] Dataset item ID (required)
    # @param run_name [String] Run name (required)
    # @param trace_id [String, nil] Trace ID to link
    # @param observation_id [String, nil] Observation ID to link
    # @param metadata [Hash, nil] Optional metadata
    # @param run_description [String, nil] Optional run description
    # @return [Hash] The created dataset run item data
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   api_client.create_dataset_run_item(dataset_item_id: "item-123", run_name: "eval-v1", trace_id: "trace-abc")
    def create_dataset_run_item(dataset_item_id:, run_name:, trace_id: nil,
                                observation_id: nil, metadata: nil, run_description: nil)
      @dataset_resource.create_dataset_run_item(
        dataset_item_id: dataset_item_id,
        run_name: run_name,
        trace_id: trace_id,
        observation_id: observation_id,
        metadata: metadata,
        run_description: run_description
      )
    end

    # Fetch a dataset run by dataset and run name
    #
    # @param dataset_name [String] Dataset name (required)
    # @param run_name [String] Run name (required)
    # @return [Hash] The dataset run data
    # @raise [NotFoundError] if the dataset run is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def get_dataset_run(dataset_name:, run_name:)
      @dataset_resource.get_dataset_run(dataset_name: dataset_name, run_name: run_name)
    end

    # List dataset runs in a dataset
    #
    # @param dataset_name [String] Dataset name (required)
    # @param page [Integer, nil] Optional page number for pagination
    # @param limit [Integer, nil] Optional limit per page
    # @return [Array<Hash>] Array of dataset run hashes
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def list_dataset_runs(dataset_name:, page: nil, limit: nil)
      @dataset_resource.list_dataset_runs(dataset_name: dataset_name, page: page, limit: limit)
    end

    # Full paginated response including "meta" for internal pagination use
    #
    # @api private
    # @return [Hash] Full response hash with "data" array and "meta" pagination info
    def list_dataset_runs_paginated(dataset_name:, page: nil, limit: nil)
      @dataset_resource.list_dataset_runs_paginated(dataset_name: dataset_name, page: page, limit: limit)
    end

    # Delete a dataset run by name
    #
    # @param dataset_name [String] Dataset name (required)
    # @param run_name [String] Run name (required)
    # @return [Hash, nil] Response body, or nil for 204 responses
    # @raise [NotFoundError] if the dataset run is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    # @note 404 responses raise NotFoundError to preserve strict delete semantics
    def delete_dataset_run(dataset_name:, run_name:)
      @dataset_resource.delete_dataset_run(dataset_name: dataset_name, run_name: run_name)
    end

    # Fetch projects accessible with the current API keys
    #
    # @return [Hash] The parsed response body containing project data
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   data = api_client.get_projects
    #   project_id = data["data"][0]["id"]
    def get_projects # rubocop:disable Naming/AccessorMethodName
      with_faraday_error_handling do
        response = connection.get("/api/public/projects")
        handle_response(response)
      end
    end

    # Shut down the API client and release resources
    #
    # Shuts down the cache if it supports shutdown (e.g., SWR thread pool).
    #
    # @return [void]
    def shutdown
      @cache_capabilities.shutdown
    end

    # List traces in the project
    #
    # @param page [Integer, nil] Optional page number for pagination
    # @param limit [Integer, nil] Optional limit per page
    # @param user_id [String, nil] Filter by user ID
    # @param name [String, nil] Filter by trace name
    # @param session_id [String, nil] Filter by session ID
    # @param from_timestamp [Time, nil] Filter traces after this time
    # @param to_timestamp [Time, nil] Filter traces before this time
    # @param order_by [String, nil] Order by field
    # @param tags [Array<String>, nil] Filter by tags
    # @param version [String, nil] Filter by version
    # @param release [String, nil] Filter by release
    # @param environment [String, nil] Filter by environment
    # @param fields [String, nil] Comma-separated field groups to include (e.g. "core,scores,metrics")
    # @param filter [String, nil] JSON string for advanced filtering
    # @return [Array<Hash>] Array of trace hashes
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   traces = api_client.list_traces(page: 1, limit: 10, name: "my-trace")
    # rubocop:disable Metrics/ParameterLists
    def list_traces(page: nil, limit: nil, user_id: nil, name: nil, session_id: nil,
                    from_timestamp: nil, to_timestamp: nil, order_by: nil,
                    tags: nil, version: nil, release: nil, environment: nil,
                    fields: nil, filter: nil)
      @trace_resource.list(
        page: page, limit: limit, user_id: user_id, name: name,
        session_id: session_id, from_timestamp: from_timestamp,
        to_timestamp: to_timestamp, order_by: order_by, tags: tags,
        version: version, release: release, environment: environment,
        fields: fields, filter: filter
      )
    end
    # rubocop:enable Metrics/ParameterLists

    # Full paginated response including "meta" for internal pagination use
    #
    # @api private
    # @return [Hash] Full response hash with "data" array and "meta" pagination info
    # rubocop:disable Metrics/ParameterLists
    def list_traces_paginated(page: nil, limit: nil, user_id: nil, name: nil, session_id: nil,
                              from_timestamp: nil, to_timestamp: nil, order_by: nil,
                              tags: nil, version: nil, release: nil, environment: nil,
                              fields: nil, filter: nil)
      @trace_resource.list_paginated(
        page: page, limit: limit, user_id: user_id, name: name,
        session_id: session_id, from_timestamp: from_timestamp,
        to_timestamp: to_timestamp, order_by: order_by, tags: tags,
        version: version, release: release, environment: environment,
        fields: fields, filter: filter
      )
    end
    # rubocop:enable Metrics/ParameterLists

    # Fetch a trace by ID
    #
    # @param id [String] Trace ID
    # @return [Hash] The trace data
    # @raise [NotFoundError] if the trace is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   trace = api_client.get_trace("trace-uuid-123")
    def get_trace(id)
      @trace_resource.get(id)
    end

    # List all datasets in the project
    #
    # @param page [Integer, nil] Optional page number for pagination
    # @param limit [Integer, nil] Optional limit per page
    # @return [Array<Hash>] Array of dataset metadata hashes
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   datasets = api_client.list_datasets(page: 1, limit: 10)
    def list_datasets(page: nil, limit: nil)
      @dataset_resource.list_datasets(page: page, limit: limit)
    end

    # Fetch a dataset by name
    #
    # @param name [String] Dataset name (supports folder paths like "evaluation/qa-dataset")
    # @return [Hash] The dataset data
    # @raise [NotFoundError] if the dataset is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   data = api_client.get_dataset("my-dataset")
    def get_dataset(name)
      @dataset_resource.get_dataset(name)
    end

    # Create a new dataset
    #
    # @param name [String] Dataset name (required)
    # @param description [String, nil] Optional description
    # @param metadata [Hash, nil] Optional metadata hash
    # @return [Hash] The created dataset data
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   data = api_client.create_dataset(name: "my-dataset", description: "QA evaluation set")
    def create_dataset(name:, description: nil, metadata: nil)
      @dataset_resource.create_dataset(name: name, description: description, metadata: metadata)
    end

    # Create a new dataset item (or upsert if id is provided)
    #
    # @param dataset_name [String] Name of the dataset (required)
    # @param input [Object, nil] Input data for the item
    # @param expected_output [Object, nil] Expected output for evaluation
    # @param metadata [Hash, nil] Optional metadata
    # @param id [String, nil] Optional ID for upsert behavior
    # @param source_trace_id [String, nil] Link to source trace
    # @param source_observation_id [String, nil] Link to source observation
    # @param status [Symbol, nil] Item status (:active or :archived)
    # @return [Hash] The created dataset item data
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   data = api_client.create_dataset_item(
    #     dataset_name: "my-dataset",
    #     input: { query: "What is Ruby?" },
    #     expected_output: { answer: "A programming language" }
    #   )
    # rubocop:disable Metrics/ParameterLists
    def create_dataset_item(dataset_name:, input: nil, expected_output: nil,
                            metadata: nil, id: nil, source_trace_id: nil,
                            source_observation_id: nil, status: nil)
      @dataset_resource.create_dataset_item(
        dataset_name: dataset_name,
        input: input,
        expected_output: expected_output,
        metadata: metadata,
        id: id,
        source_trace_id: source_trace_id,
        source_observation_id: source_observation_id,
        status: status
      )
    end
    # rubocop:enable Metrics/ParameterLists

    # Fetch a dataset item by ID
    #
    # @param id [String] Dataset item ID
    # @return [Hash] The dataset item data
    # @raise [NotFoundError] if the item is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   data = api_client.get_dataset_item("item-uuid-123")
    def get_dataset_item(id)
      @dataset_resource.get_dataset_item(id)
    end

    # List items in a dataset with optional filters
    #
    # @param dataset_name [String] Name of the dataset (required)
    # @param page [Integer, nil] Optional page number for pagination
    # @param limit [Integer, nil] Optional limit per page
    # @param source_trace_id [String, nil] Filter by source trace ID
    # @param source_observation_id [String, nil] Filter by source observation ID
    # @return [Array<Hash>] Array of dataset item hashes
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   items = api_client.list_dataset_items(dataset_name: "my-dataset", limit: 50)
    def list_dataset_items(dataset_name:, page: nil, limit: nil,
                           source_trace_id: nil, source_observation_id: nil)
      @dataset_resource.list_dataset_items(
        dataset_name: dataset_name, page: page, limit: limit,
        source_trace_id: source_trace_id, source_observation_id: source_observation_id
      )
    end

    # Full paginated response including "meta" for internal pagination use
    #
    # @api private
    # @return [Hash] Full response hash with "data" array and "meta" pagination info
    def list_dataset_items_paginated(dataset_name:, page: nil, limit: nil,
                                     source_trace_id: nil, source_observation_id: nil)
      @dataset_resource.list_dataset_items_paginated(
        dataset_name: dataset_name, page: page, limit: limit,
        source_trace_id: source_trace_id, source_observation_id: source_observation_id
      )
    end

    # Delete a dataset item by ID
    #
    # @param id [String] Dataset item ID
    # @return [Hash] The response body
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    # @note 404 responses are treated as success to keep DELETE idempotent across retries
    #
    # @example
    #   api_client.delete_dataset_item("item-uuid-123")
    def delete_dataset_item(id)
      @dataset_resource.delete_dataset_item(id)
    end

    private

    attr_reader :cache_backend_name

    def initialize_resources
      dependencies = resource_dependencies
      @prompt_resource = build_prompt_resource(dependencies)
      @batch_resource = build_batch_resource(dependencies)
      @dataset_resource = build_dataset_resource(dependencies)
      @trace_resource = build_trace_resource(dependencies)
    end

    def resource_dependencies
      response_handler = ->(response) { handle_response(response) }
      error_handler = ->(&block) { with_faraday_error_handling(&block) }
      connection_factory = -> { connection }
      {
        connection: connection_factory,
        response_handler: response_handler,
        error_handler: error_handler
      }
    end

    def build_prompt_resource(dependencies)
      Resources::Prompts.new(
        connection: dependencies.fetch(:connection),
        handle_response: dependencies.fetch(:response_handler),
        with_error_handling: dependencies.fetch(:error_handler),
        invalidate_cache: ->(name) { @prompt_cache_coordinator.invalidate_after_mutation(name) }
      )
    end

    def build_batch_resource(dependencies)
      Resources::Batches.new(
        connection: dependencies.fetch(:connection),
        handle_batch_response: ->(response) { handle_batch_response(response) },
        logger: logger
      )
    end

    def build_dataset_resource(dependencies)
      Resources::Datasets.new(
        connection: dependencies.fetch(:connection),
        handle_response: dependencies.fetch(:response_handler),
        handle_delete_dataset_item_response: ->(response, id) { handle_delete_dataset_item_response(response, id) },
        with_error_handling: dependencies.fetch(:error_handler),
        logger: logger
      )
    end

    def build_trace_resource(dependencies)
      Resources::Traces.new(
        connection: dependencies.fetch(:connection),
        handle_response: dependencies.fetch(:response_handler),
        with_error_handling: dependencies.fetch(:error_handler)
      )
    end

    # Fetch a prompt from the API (without caching)
    #
    # @param name [String] The name of the prompt
    # @param version [Integer, nil] Optional specific version number
    # @param label [String, nil] Optional label
    # @return [Hash] The prompt data
    # @raise [NotFoundError] if the prompt is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def fetch_prompt_from_api(name, version: nil, label: nil)
      @prompt_resource.fetch(name, version: version, label: label)
    end

    # Build a new Faraday connection
    #
    # @param timeout [Integer, nil] Optional timeout override
    # @return [Faraday::Connection]
    def build_connection(timeout: nil)
      Faraday.new(
        url: base_url,
        headers: default_headers
      ) do |conn|
        conn.request :json
        conn.request :retry, retry_options
        conn.response :json, content_type: /\bjson$/
        conn.adapter Faraday.default_adapter
        conn.options.timeout = timeout || @timeout
      end
    end

    # Configuration for retry middleware
    #
    # Retries transient errors with exponential backoff:
    # - Max 2 retries (3 total attempts)
    # - Exponential backoff (0.05s * 2^retry_count)
    # - Retries GET, PATCH, and DELETE requests (idempotent operations)
    # - Retries POST requests to batch endpoint (idempotent due to event UUIDs)
    # - Note: POST to create_prompt is NOT idempotent; retries may create duplicate versions
    # - Retries on: 429 (rate limit), 503 (service unavailable), 504 (gateway timeout)
    # - Does NOT retry on: 4xx errors (except 429), 5xx errors (except 503, 504)
    #
    # @return [Hash] Retry options for Faraday::Retry middleware
    def retry_options
      {
        max: 2,
        interval: 0.05,
        backoff_factor: 2,
        methods: %i[get post patch delete],
        retry_statuses: [429, 503, 504],
        exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      }
    end

    # Default headers for all requests
    #
    # @return [Hash]
    def default_headers
      {
        "Authorization" => authorization_header,
        "User-Agent" => user_agent,
        "Content-Type" => "application/json"
      }
    end

    # Generate Basic Auth header
    #
    # @return [String] Basic Auth header value
    def authorization_header
      credentials = "#{public_key}:#{secret_key}"
      "Basic #{Base64.strict_encode64(credentials)}"
    end

    # User agent string
    #
    # @return [String]
    def user_agent
      "langfuse-rb/#{Langfuse::VERSION}"
    end

    # Wrap a block with standard Faraday error handling.
    #
    # Catches RetriableResponse (retries exhausted) and generic Faraday errors,
    # translating them into ApiError with consistent logging.
    #
    # @yield The block containing the Faraday request and response handling
    # @return [Object] The return value of the block
    # @raise [ApiError] when a Faraday error occurs
    def with_faraday_error_handling
      yield
    rescue Faraday::RetriableResponse => e
      logger.error("Faraday error: Retries exhausted - #{e.response.status}")
      handle_response(e.response)
    rescue Faraday::Error => e
      logger.error("Faraday error: #{e.message}")
      raise ApiError, "HTTP request failed: #{e.message}"
    end

    # Handle HTTP response and raise appropriate errors
    #
    # @param response [Faraday::Response] The HTTP response
    # @return [Hash] The parsed response body
    # @raise [NotFoundError] if status is 404
    # @raise [UnauthorizedError] if status is 401
    # @raise [ApiError] for other error statuses
    def handle_response(response)
      case response.status
      when 200, 201
        response.body
      when 401
        raise UnauthorizedError, "Authentication failed. Check your API keys."
      when 404
        raise NotFoundError, extract_error_message(response)
      else
        error_message = extract_error_message(response)
        raise ApiError, "API request failed (#{response.status}): #{error_message}"
      end
    end

    def handle_delete_dataset_item_response(response, id)
      return { "id" => id } if response&.status == 404
      return response.body if [200, 201].include?(response&.status)

      handle_response(response)
    end

    # Handle HTTP response for batch requests
    #
    # @param response [Faraday::Response] The HTTP response
    # @return [void]
    # @raise [UnauthorizedError] if status is 401
    # @raise [ApiError] for other error statuses
    def handle_batch_response(response)
      case response.status
      when 200, 201, 204, 207
        nil
      when 401
        raise UnauthorizedError, "Authentication failed. Check your API keys."
      else
        error_message = extract_error_message(response)
        raise ApiError, "Batch send failed (#{response.status}): #{error_message}"
      end
    end

    # Extract error message from response body
    #
    # @param response [Faraday::Response] The HTTP response
    # @return [String] The error message
    def extract_error_message(response)
      body_hash = case response.body
                  in Hash => h then h
                  in String => s then begin
                    JSON.parse(s)
                  rescue StandardError
                    {}
                  end
                  else {}
                  end

      %w[message error].filter_map { |key| body_hash[key] }.first || "Unknown error"
    end
  end
end
