# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "base64"
require "json"
require "time"
require "uri"
require_relative "sdk_headers"
require_relative "prompt_fetch_result"
require_relative "prompt_cache_coordinator"

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
      setup_prompt_cache_events(cache_observer: cache_observer)
      @prompt_cache_coordinator = PromptCacheCoordinator.new(
        cache: cache,
        event_emitter: self,
        fetch_prompt: ->(name, version:, label:) { fetch_prompt_from_api(name, version: version, label: label) }
      )
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
      request(:get, "/api/public/v2/prompts", params: { page: page, limit: limit }.compact)["data"] || []
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
    # rubocop:disable Naming/PredicateMethod
    def validate_prompt_cache_backend!
      @cache&.validate!
      true
    end
    # rubocop:enable Naming/PredicateMethod

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
      payload = {
        name: name, prompt: prompt, type: type, config: config,
        labels: labels, tags: tags, commitMessage: commit_message
      }.compact
      request(:post, "/api/public/v2/prompts", body: payload)
        .tap { @prompt_cache_coordinator.invalidate_after_mutation(name) }
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
      raise ArgumentError, "labels must be an array" unless labels.is_a?(Array)

      path = "/api/public/v2/prompts/#{URI.encode_uri_component(name)}/versions/#{version}"
      request(:patch, path, body: { newLabels: labels })
        .tap { @prompt_cache_coordinator.invalidate_after_mutation(name) }
    end

    # Delete prompt versions.
    #
    # @param name [String] Prompt name
    # @param version [Integer, nil] Optional version to delete
    # @param label [String, nil] Optional label filter for deletion
    # @return [nil]
    # @raise [NotFoundError] if the prompt is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def delete_prompt(name, version: nil, label: nil)
      path = "/api/public/v2/prompts/#{URI.encode_uri_component(name)}"
      request(:delete, path, params: { version: version, label: label }.compact)
      @prompt_cache_coordinator.invalidate_after_mutation(name)
      nil
    end

    # Fetch a media record and its temporary download URL.
    #
    # @param media_id [String] Langfuse media ID
    # @return [Hash] Media record
    # @raise [NotFoundError] if the media record is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def get_media(media_id)
      request(:get, "/api/public/media/#{URI.encode_uri_component(media_id)}")
    end

    # Get a presigned upload URL for a media record.
    #
    # @param trace_id [String] Associated trace ID
    # @param content_type [String] MIME type
    # @param content_length [Integer] Media byte length
    # @param sha256_hash [String] Base64-encoded SHA256 digest
    # @param field [String, Symbol] Trace/observation field: input, output, or metadata
    # @param observation_id [String, nil] Associated observation ID
    # @return [Hash] Upload URL response
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def get_media_upload_url(trace_id:, content_type:, content_length:, sha256_hash:, field:, observation_id: nil)
      request(:post, "/api/public/media", body: {
        traceId: trace_id, observationId: observation_id, contentType: content_type,
        contentLength: content_length, sha256Hash: sha256_hash, field: field
      }.compact)
    end

    # Patch media upload status after uploading to the presigned URL.
    #
    # @param media_id [String] Langfuse media ID
    # @param uploaded_at [Time, String] Upload completion timestamp
    # @param upload_http_status [Integer] HTTP status returned by object storage
    # @param upload_http_error [String, nil] Upload error message
    # @param upload_time_ms [Integer, nil] Upload duration in milliseconds
    # @return [Hash] Patched media record
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def patch_media(media_id:, uploaded_at:, upload_http_status:, upload_http_error: nil, upload_time_ms: nil)
      request(:patch, "/api/public/media/#{URI.encode_uri_component(media_id)}", body: {
        uploadedAt: format_timestamp(uploaded_at), uploadHttpStatus: upload_http_status,
        uploadHttpError: upload_http_error, uploadTimeMs: upload_time_ms
      }.compact)
    end

    # Upload media bytes through Langfuse's presigned media flow.
    #
    # @param media [Media] Media wrapper
    # @param trace_id [String] Associated trace ID
    # @param field [String, Symbol] Trace/observation field: input, output, or metadata
    # @param observation_id [String, nil] Associated observation ID
    # @param timeout [Integer, nil] Upload timeout override
    # @return [String] Langfuse media reference token
    # @raise [ArgumentError] if media is invalid
    # @raise [ApiError] if the upload fails
    def upload_media(media, trace_id:, field:, observation_id: nil, timeout: nil)
      validate_media_upload!(media)
      upload = get_media_upload_url(
        trace_id: trace_id, content_type: media.content_type, content_length: media.content_length,
        sha256_hash: media.content_sha256_hash, field: field, observation_id: observation_id
      )
      upload_media_to_presigned_url(media, upload, timeout: timeout)
      media.reference_string
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
      raise ArgumentError, "events must be an array" unless events.is_a?(Array)
      raise ArgumentError, "events array cannot be empty" if events.empty?

      response = connection.post("/api/public/ingestion", { batch: events })
      handle_batch_response(response)
    rescue Faraday::RetriableResponse => e
      logger.error("Langfuse batch send failed: Retries exhausted - #{e.response.status}")
      handle_batch_response(e.response)
    rescue Faraday::Error => e
      logger.error("Langfuse batch send failed: #{e.message}")
      raise ApiError, "Batch send failed: #{e.message}"
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
      payload = {
        datasetItemId: dataset_item_id, runName: run_name,
        traceId: trace_id, observationId: observation_id,
        metadata: metadata, runDescription: run_description
      }.compact
      request(:post, "/api/public/dataset-run-items", body: payload)
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
      request(:get, dataset_run_path(dataset_name: dataset_name, run_name: run_name))
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
      list_dataset_runs_paginated(dataset_name: dataset_name, page: page, limit: limit)["data"] || []
    end

    # Full paginated response including "meta" for internal pagination use
    #
    # @api private
    # @return [Hash] Full response hash with "data" array and "meta" pagination info
    def list_dataset_runs_paginated(dataset_name:, page: nil, limit: nil)
      request(:get, dataset_runs_path(dataset_name), params: { page: page, limit: limit }.compact)
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
      with_faraday_error_handling do
        response = connection.delete(dataset_run_path(dataset_name: dataset_name, run_name: run_name))
        response.status == 204 ? nil : handle_response(response)
      end
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
      request(:get, "/api/public/projects")
    end

    # Check Langfuse API health.
    #
    # @return [Hash] Health response
    # @raise [ApiError] for API errors
    def health
      request(:get, "/api/public/health")
    end

    # List sessions.
    #
    # @param filters [Hash] Optional filters: page, limit, from_timestamp, to_timestamp, environment
    # @return [Array<Hash>] Session records
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def list_sessions(**filters)
      list_sessions_paginated(**filters)["data"] || []
    end

    # Fetch one session including traces.
    #
    # @param session_id [String] Session ID
    # @return [Hash] Session record
    # @raise [NotFoundError] if the session is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def get_session(session_id)
      request(:get, "/api/public/sessions/#{URI.encode_uri_component(session_id)}")
    end

    # Full paginated sessions response including "meta".
    #
    # @api private
    # @param filters [Hash] Optional filters
    # @return [Hash] Full response hash
    def list_sessions_paginated(**filters)
      request(:get, "/api/public/sessions", params: transform_query_options(filters))
    end

    # List observations through the v2 read API.
    #
    # @param filters [Hash] Optional v2 filters using snake_case keys
    # @return [Array<Hash>] Observation records
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def list_observations(**filters)
      list_observations_paginated(**filters)["data"] || []
    end

    # Full v2 observations response including cursor metadata.
    #
    # @api private
    # @param filters [Hash] Optional v2 filters using snake_case keys
    # @return [Hash] Full response hash
    def list_observations_paginated(**filters)
      request(:get, "/api/public/v2/observations", params: transform_query_options(filters))
    end

    # List scores through the v2 read API.
    #
    # @param filters [Hash] Optional v2 filters using snake_case keys
    # @return [Array<Hash>] Score records
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def list_scores(**filters)
      list_scores_paginated(**filters)["data"] || []
    end

    # Fetch one score through the v2 read API.
    #
    # @param score_id [String] Score ID
    # @return [Hash] Score record
    # @raise [NotFoundError] if the score is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def get_score(score_id)
      request(:get, "/api/public/v2/scores/#{URI.encode_uri_component(score_id)}")
    end

    # Full v2 scores response including "meta".
    #
    # @api private
    # @param filters [Hash] Optional v2 filters using snake_case keys
    # @return [Hash] Full response hash
    def list_scores_paginated(**filters)
      request(:get, "/api/public/v2/scores", params: transform_query_options(filters))
    end

    # Create a score config.
    #
    # @param attributes [Hash] Score config attributes using snake_case keys
    # @return [Hash] Score config record
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def create_score_config(**attributes)
      request(:post, "/api/public/score-configs", body: transform_body_options(attributes))
    end

    # List score configs.
    #
    # @param page [Integer, nil] Page number
    # @param limit [Integer, nil] Page size
    # @return [Array<Hash>] Score config records
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def list_score_configs(page: nil, limit: nil)
      request(:get, "/api/public/score-configs", params: { page: page, limit: limit }.compact)["data"] || []
    end

    # Fetch one score config.
    #
    # @param config_id [String] Score config ID
    # @return [Hash] Score config record
    # @raise [NotFoundError] if the score config is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def get_score_config(config_id)
      request(:get, "/api/public/score-configs/#{URI.encode_uri_component(config_id)}")
    end

    # Update a score config.
    #
    # @param config_id [String] Score config ID
    # @param attributes [Hash] Score config attributes using snake_case keys
    # @return [Hash] Score config record
    # @raise [NotFoundError] if the score config is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def update_score_config(config_id:, **attributes)
      request(:patch, "/api/public/score-configs/#{URI.encode_uri_component(config_id)}",
              body: transform_body_options(attributes))
    end

    # Create a model.
    #
    # @param attributes [Hash] Model attributes using snake_case keys
    # @return [Hash] Model record
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def create_model(**attributes)
      request(:post, "/api/public/models", body: transform_body_options(attributes))
    end

    # List models.
    #
    # @param page [Integer, nil] Page number
    # @param limit [Integer, nil] Page size
    # @return [Array<Hash>] Model records
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def list_models(page: nil, limit: nil)
      request(:get, "/api/public/models", params: { page: page, limit: limit }.compact)["data"] || []
    end

    # Fetch one model.
    #
    # @param id [String] Model ID
    # @return [Hash] Model record
    # @raise [NotFoundError] if the model is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def get_model(id)
      request(:get, "/api/public/models/#{URI.encode_uri_component(id)}")
    end

    # Delete one model.
    #
    # @param id [String] Model ID
    # @return [nil]
    # @raise [NotFoundError] if the model is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def delete_model(id)
      request(:delete, "/api/public/models/#{URI.encode_uri_component(id)}")
      nil
    end

    # Query metrics through the v2 metrics API.
    #
    # @param query [Hash, String] Metrics query hash or JSON string
    # @return [Hash] Metrics response
    # @raise [ArgumentError] if query is empty
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def query_metrics(query:)
      raise ArgumentError, "query is required" if query.nil? || query == ""

      encoded_query = query.is_a?(String) ? query : JSON.generate(query)
      request(:get, "/api/public/v2/metrics", params: { query: encoded_query })
    end

    # Shut down the API client and release resources
    #
    # Shuts down the cache backend's SWR thread pool when present.
    #
    # @return [void]
    def shutdown
      @cache&.shutdown
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
      list_traces_paginated(
        page: page, limit: limit, user_id: user_id, name: name,
        session_id: session_id, from_timestamp: from_timestamp,
        to_timestamp: to_timestamp, order_by: order_by, tags: tags,
        version: version, release: release, environment: environment,
        fields: fields, filter: filter
      )["data"] || []
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
      params = build_traces_params(
        page: page, limit: limit, user_id: user_id, name: name,
        session_id: session_id, from_timestamp: from_timestamp,
        to_timestamp: to_timestamp, order_by: order_by, tags: tags,
        version: version, release: release, environment: environment,
        fields: fields, filter: filter
      )
      request(:get, "/api/public/traces", params: params)
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
      request(:get, "/api/public/traces/#{URI.encode_uri_component(id)}")
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
      request(:get, "/api/public/v2/datasets", params: { page: page, limit: limit }.compact)["data"] || []
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
      request(:get, "/api/public/v2/datasets/#{URI.encode_uri_component(name)}")
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
      request(:post, "/api/public/v2/datasets",
              body: { name: name, description: description, metadata: metadata }.compact)
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
      payload = {
        datasetName: dataset_name, id: id, input: input,
        expectedOutput: expected_output, metadata: metadata,
        sourceTraceId: source_trace_id, sourceObservationId: source_observation_id,
        status: status&.to_s&.upcase
      }.compact
      request(:post, "/api/public/dataset-items", body: payload)
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
      request(:get, "/api/public/dataset-items/#{URI.encode_uri_component(id)}")
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
    def list_dataset_items(**)
      list_dataset_items_paginated(**)["data"] || []
    end

    # Full paginated response including "meta" for internal pagination use
    #
    # @api private
    # @return [Hash] Full response hash with "data" array and "meta" pagination info
    def list_dataset_items_paginated(dataset_name:, page: nil, limit: nil,
                                     source_trace_id: nil, source_observation_id: nil)
      params = {
        datasetName: dataset_name, page: page, limit: limit,
        sourceTraceId: source_trace_id, sourceObservationId: source_observation_id
      }.compact
      request(:get, "/api/public/dataset-items", params: params)
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
      response = connection.delete("/api/public/dataset-items/#{URI.encode_uri_component(id)}")
      handle_delete_dataset_item_response(response, id)
    rescue Faraday::RetriableResponse => e
      logger.error("Faraday error: Retries exhausted - #{e.response.status}")
      handle_delete_dataset_item_response(e.response, id)
    rescue Faraday::Error => e
      logger.error("Faraday error: #{e.message}")
      raise ApiError, "HTTP request failed: #{e.message}"
    end

    private

    def cache_backend_name
      @prompt_cache_coordinator.backend_name
    end

    def validate_media_upload!(media)
      return if media.respond_to?(:valid?) && media.valid? && media.respond_to?(:reference_string)

      raise ArgumentError, "media must be a valid Langfuse::Media"
    end

    def upload_media_to_presigned_url(media, upload, timeout:)
      upload_url = upload["uploadUrl"]
      return if upload_url.nil? || upload_url.empty?

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = perform_media_put(upload_url, media, timeout)
      patch_uploaded_media(media, response, started)
      raise ApiError, "Media upload failed (#{response.status})" unless response.status.between?(200, 299)
    rescue Faraday::Error => e
      patch_failed_media(media, e, started)
      raise ApiError, "Media upload failed: #{e.message}"
    end

    def perform_media_put(upload_url, media, timeout)
      media_upload_connection(upload_url, timeout).put do |request|
        media_upload_headers(upload_url, media).each { |key, value| request.headers[key] = value }
        request.body = media.content_bytes
      end
    end

    def patch_uploaded_media(media, response, started)
      patch_media(
        media_id: media.media_id,
        uploaded_at: Time.now.utc,
        upload_http_status: response.status,
        upload_http_error: response.status.between?(200, 299) ? nil : response.body.to_s,
        upload_time_ms: elapsed_ms(started)
      )
    end

    def patch_failed_media(media, error, started)
      patch_media(
        media_id: media.media_id,
        uploaded_at: Time.now.utc,
        upload_http_status: 0,
        upload_http_error: error.message,
        upload_time_ms: elapsed_ms(started)
      )
    rescue ApiError
      nil
    end

    def media_upload_connection(upload_url, timeout)
      Faraday.new(url: upload_url) do |conn|
        conn.options.timeout = timeout || @timeout
        conn.adapter Faraday.default_adapter
      end
    end

    def media_upload_headers(upload_url, media)
      headers = { "Content-Type" => media.content_type }
      return headers if gcs_upload_url?(upload_url)

      headers.merge(
        "x-amz-checksum-sha256" => media.content_sha256_hash,
        "x-ms-blob-type" => "BlockBlob"
      )
    end

    def gcs_upload_url?(upload_url)
      host = URI.parse(upload_url).host.to_s
      host == "storage.googleapis.com" || host.end_with?(".storage.googleapis.com")
    rescue URI::InvalidURIError
      false
    end

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end

    def transform_query_options(options)
      transform_options(options) { |value| format_query_value(value) }
    end

    def transform_body_options(options)
      transform_options(options) { |value| transform_body_value(value) }
    end

    def transform_body_value(value)
      case value
      when Hash
        transform_body_options(value)
      when Array
        value.map { |item| transform_body_value(item) }
      else
        value
      end
    end

    def transform_options(options)
      options.each_with_object({}) do |(key, value), params|
        next if value.nil?

        params[camelize_key(key)] = yield(value)
      end
    end

    def camelize_key(key)
      parts = key.to_s.split("_")
      ([parts.first] + parts[1..].map(&:capitalize)).join.to_sym
    end

    def format_query_value(value)
      value.respond_to?(:iso8601) ? value.iso8601 : value
    end

    def format_timestamp(value)
      value.respond_to?(:iso8601) ? value.iso8601 : value
    end

    # Issue an HTTP request, raise on Faraday errors, parse the response.
    #
    # @api private
    # @param verb [Symbol] HTTP verb (:get, :post, :patch, :delete)
    # @param path [String] Request path
    # @param params [Hash, nil] Query string params (GET/DELETE)
    # @param body [Hash, nil] JSON body (POST/PATCH)
    # @return [Hash] Parsed response body
    def request(verb, path, params: nil, body: nil)
      with_faraday_error_handling do
        handle_response(connection.public_send(verb, path, body || params))
      end
    end

    def build_traces_params(**options)
      {
        page: options[:page], limit: options[:limit], userId: options[:user_id], name: options[:name],
        sessionId: options[:session_id],
        fromTimestamp: options[:from_timestamp]&.iso8601,
        toTimestamp: options[:to_timestamp]&.iso8601,
        orderBy: options[:order_by], tags: options[:tags], version: options[:version],
        release: options[:release], environment: options[:environment], fields: options[:fields],
        filter: options[:filter]
      }.compact
    end

    def dataset_runs_path(dataset_name)
      "/api/public/datasets/#{URI.encode_uri_component(dataset_name)}/runs"
    end

    def dataset_run_path(dataset_name:, run_name:)
      "#{dataset_runs_path(dataset_name)}/#{URI.encode_uri_component(run_name)}"
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
      path = "/api/public/v2/prompts/#{URI.encode_uri_component(name)}"
      request(:get, path, params: { version: version, label: label }.compact)
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
      }.merge(SdkHeaders.rest(public_key: public_key))
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
      when 204
        nil
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
