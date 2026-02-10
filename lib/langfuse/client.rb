# frozen_string_literal: true

module Langfuse
  # Main client for Langfuse SDK
  #
  # Provides a unified interface for interacting with the Langfuse API.
  # Handles prompt fetching and returns the appropriate prompt client
  # (TextPromptClient or ChatPromptClient) based on the prompt type.
  #
  # @example
  #   config = Langfuse::Config.new(
  #     public_key: "pk_...",
  #     secret_key: "sk_...",
  #     cache_ttl: 120
  #   )
  #   client = Langfuse::Client.new(config)
  #   prompt = client.get_prompt("greeting")
  #   compiled = prompt.compile(name: "Alice")
  #
  # rubocop:disable Metrics/ClassLength
  class Client
    # @return [Integer] Default page size when fetching all dataset items
    DATASET_ITEMS_PAGE_SIZE = 50

    # @return [Config] The client configuration
    attr_reader :config

    # @return [ApiClient] The underlying API client
    attr_reader :api_client

    # Initialize a new Langfuse client
    #
    # @param config [Config] Configuration object
    # @return [Client]
    def initialize(config)
      @config = config
      @config.validate!

      # Create cache if enabled
      cache = create_cache if cache_enabled?

      # Create API client with cache
      @api_client = ApiClient.new(
        public_key: config.public_key,
        secret_key: config.secret_key,
        base_url: config.base_url,
        timeout: config.timeout,
        logger: config.logger,
        cache: cache
      )

      @project_id = nil
      # One-shot lookup: avoids repeated blocking API calls in URL helpers
      # (trace_url, dataset_url, dataset_run_url) when the project endpoint is down.
      @project_id_fetched = false

      # Initialize score client for batching score events
      @score_client = ScoreClient.new(api_client: @api_client, config: config)
    end

    # Fetch a prompt and return the appropriate client
    #
    # Fetches the prompt from the Langfuse API and returns either a
    # TextPromptClient or ChatPromptClient based on the prompt type.
    #
    # @param name [String] The name of the prompt
    # @param version [Integer, nil] Optional specific version number
    # @param label [String, nil] Optional label (e.g., "production", "latest")
    # @param fallback [String, Array, nil] Optional fallback prompt to use on error
    # @param type [Symbol, nil] Required when fallback is provided (:text or :chat)
    # @return [TextPromptClient, ChatPromptClient] The prompt client
    # @raise [ArgumentError] if both version and label are provided
    # @raise [ArgumentError] if fallback is provided without type
    # @raise [NotFoundError] if the prompt is not found and no fallback provided
    # @raise [UnauthorizedError] if authentication fails and no fallback provided
    # @raise [ApiError] for other API errors and no fallback provided
    #
    # @example With fallback for graceful degradation
    #   prompt = client.get_prompt("greeting", fallback: "Hello {{name}}!", type: :text)
    def get_prompt(name, version: nil, label: nil, fallback: nil, type: nil)
      # Validate fallback usage
      if fallback && !type
        raise ArgumentError, "type parameter is required when fallback is provided (use :text or :chat)"
      end

      # Try to fetch from API
      prompt_data = api_client.get_prompt(name, version: version, label: label)
      build_prompt_client(prompt_data)
    rescue ApiError, NotFoundError, UnauthorizedError => e
      # If no fallback, re-raise the error
      raise e unless fallback

      # Log warning and return fallback
      config.logger.warn("Langfuse API error for prompt '#{name}': #{e.message}. Using fallback.")
      build_fallback_prompt_client(name, fallback, type)
    end

    # List all prompts in the Langfuse project
    #
    # Fetches a list of all prompt names available in your project.
    # Returns metadata only, not full prompt content.
    #
    # @param page [Integer, nil] Optional page number for pagination
    # @param limit [Integer, nil] Optional limit per page
    # @return [Array<Hash>] Array of prompt metadata hashes
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   prompts = client.list_prompts
    #   prompts.each do |prompt|
    #     puts "#{prompt['name']} (v#{prompt['version']})"
    #   end
    def list_prompts(page: nil, limit: nil)
      api_client.list_prompts(page: page, limit: limit)
    end

    # Convenience method: fetch and compile a prompt in one call
    #
    # This is a shorthand for calling get_prompt followed by compile.
    # Returns the compiled prompt ready to use with your LLM.
    #
    # @param name [String] The name of the prompt
    # @param variables [Hash] Variables to substitute in the prompt
    # @param version [Integer, nil] Optional specific version number
    # @param label [String, nil] Optional label (e.g., "production", "latest")
    # @param fallback [String, Array, nil] Optional fallback prompt to use on error
    # @param type [Symbol, nil] Required when fallback is provided (:text or :chat)
    # @return [String, Array<Hash>] Compiled prompt (String for text, Array for chat)
    # @raise [ArgumentError] if both version and label are provided
    # @raise [ArgumentError] if fallback is provided without type
    # @raise [NotFoundError] if the prompt is not found and no fallback provided
    # @raise [UnauthorizedError] if authentication fails and no fallback provided
    # @raise [ApiError] for other API errors and no fallback provided
    #
    # @example Compile a text prompt
    #   text = client.compile_prompt("greeting", variables: { name: "Alice" })
    #   # => "Hello Alice!"
    #
    # @example Compile a chat prompt
    #   messages = client.compile_prompt("support-bot", variables: { company: "Acme" })
    #   # => [{ role: :system, content: "You are a support agent for Acme" }]
    #
    # @example With fallback
    #   text = client.compile_prompt(
    #     "greeting",
    #     variables: { name: "Alice" },
    #     fallback: "Hello {{name}}!",
    #     type: :text
    #   )
    def compile_prompt(name, variables: {}, version: nil, label: nil, fallback: nil, type: nil)
      prompt = get_prompt(name, version: version, label: label, fallback: fallback, type: type)
      prompt.compile(**variables)
    end

    # Create a new prompt (or new version if name already exists)
    #
    # Creates a new prompt in Langfuse. If a prompt with the same name already
    # exists, this creates a new version of that prompt.
    #
    # @param name [String] The prompt name (required)
    # @param prompt [String, Array<Hash>] The prompt content (required)
    #   - For text prompts: a string with {{variable}} placeholders
    #   - For chat prompts: array of message hashes with role and content
    # @param type [Symbol] Prompt type (:text or :chat) (required)
    # @param config [Hash] Optional configuration (model parameters, tools, etc.)
    # @param labels [Array<String>] Optional labels (e.g., ["production"])
    # @param tags [Array<String>] Optional tags for categorization
    # @param commit_message [String, nil] Optional commit message
    # @return [TextPromptClient, ChatPromptClient] The created prompt client
    # @raise [ArgumentError] if required parameters are missing or invalid
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example Create a text prompt
    #   prompt = client.create_prompt(
    #     name: "greeting",
    #     prompt: "Hello {{name}}!",
    #     type: :text,
    #     labels: ["production"],
    #     config: { model: "gpt-4o", temperature: 0.7 }
    #   )
    #
    # @example Create a chat prompt
    #   prompt = client.create_prompt(
    #     name: "support-bot",
    #     prompt: [
    #       { role: "system", content: "You are a {{role}} assistant" },
    #       { role: "user", content: "{{question}}" }
    #     ],
    #     type: :chat,
    #     labels: ["staging"]
    #   )
    # rubocop:disable Metrics/ParameterLists
    def create_prompt(name:, prompt:, type:, config: {}, labels: [], tags: [], commit_message: nil)
      validate_prompt_type!(type)
      validate_prompt_content!(prompt, type)

      prompt_data = api_client.create_prompt(
        name: name,
        prompt: normalize_prompt_content(prompt, type),
        type: type.to_s,
        config: config,
        labels: labels,
        tags: tags,
        commit_message: commit_message
      )

      build_prompt_client(prompt_data)
    end
    # rubocop:enable Metrics/ParameterLists

    # Update an existing prompt version's metadata
    #
    # Updates the labels of an existing prompt version.
    # Note: The prompt content itself cannot be changed after creation.
    #
    # @param name [String] The prompt name (required)
    # @param version [Integer] The version number to update (required)
    # @param labels [Array<String>] New labels (replaces existing). Required.
    # @return [TextPromptClient, ChatPromptClient] The updated prompt client
    # @raise [ArgumentError] if labels is not an array
    # @raise [NotFoundError] if the prompt is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example Update labels to promote to production
    #   prompt = client.update_prompt(
    #     name: "greeting",
    #     version: 2,
    #     labels: ["production"]
    #   )
    def update_prompt(name:, version:, labels:)
      prompt_data = api_client.update_prompt(
        name: name,
        version: version,
        labels: labels
      )

      build_prompt_client(prompt_data)
    end

    # Lazily-fetched project ID for URL generation
    #
    # Fetches the project ID from the API on first access and caches it.
    # Returns nil if the API call fails (URL generation is non-critical).
    #
    # @return [String, nil] The Langfuse project ID
    def project_id
      return @project_id if @project_id_fetched

      fetch_project_id
    end

    # Generate URL for viewing a trace in Langfuse UI
    #
    # @param trace_id [String] The trace ID (hex-encoded, 32 characters)
    # @return [String, nil] URL to view the trace, or nil if project ID unavailable
    #
    # @example
    #   url = client.trace_url("abc123...")
    #   puts "View trace at: #{url}"
    def trace_url(trace_id)
      project_url("traces/#{trace_id}")
    end

    # Generate URL for viewing a dataset in Langfuse UI
    #
    # @param dataset_id [String] The dataset ID
    # @return [String, nil] URL to view the dataset, or nil if project ID unavailable
    def dataset_url(dataset_id)
      project_url("datasets/#{dataset_id}")
    end

    # Generate URL for viewing a dataset run in Langfuse UI
    #
    # @param dataset_id [String] The dataset ID
    # @param dataset_run_id [String] The dataset run ID
    # @return [String, nil] URL to view the dataset run, or nil if project ID unavailable
    def dataset_run_url(dataset_id:, dataset_run_id:)
      project_url("datasets/#{dataset_id}/runs/#{dataset_run_id}")
    end

    # Create a score event and queue it for batching
    #
    # You may only provide one of the following: trace_id (with optional observation_id), session_id, or dataset_run_id; observation_id requires a trace_id.
    #
    # @param name [String] Score name (required)
    # @param value [Numeric, Integer, String] Score value (type depends on data_type)
    # @param id [String, nil] Score ID
    # @param trace_id [String, nil] Trace ID to associate with the score
    # @param session_id [String, nil] Session ID to associate with the score
    # @param observation_id [String, nil] Observation ID to associate with the score
    # @param comment [String, nil] Optional comment
    # @param metadata [Hash, nil] Optional metadata hash
    # @param environment [String, nil] Optional environment
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical)
    # @param dataset_run_id [String, nil] Optional dataset run ID to associate with the score
    # @param config_id [String, nil] Optional score config ID
    # @return [void]
    # @raise [ArgumentError] if validation fails
    #
    # @example Numeric score
    #   client.create_score(name: "quality", value: 0.85, trace_id: "abc123")
    #
    # @example Boolean score
    #   client.create_score(name: "passed", value: true, trace_id: "abc123", data_type: :boolean)
    #
    # @example Categorical score
    #   client.create_score(name: "category", value: "high", trace_id: "abc123", data_type: :categorical)
    # rubocop:disable Metrics/ParameterLists
    def create_score(name:, value:, id: nil, trace_id: nil, session_id: nil, observation_id: nil, comment: nil,
                     metadata: nil, environment: nil, data_type: :numeric, dataset_run_id: nil, config_id: nil)
      @score_client.create(
        name: name,
        value: value,
        id: id,
        trace_id: trace_id,
        session_id: session_id,
        observation_id: observation_id,
        comment: comment,
        metadata: metadata,
        environment: environment,
        data_type: data_type,
        dataset_run_id: dataset_run_id,
        config_id: config_id
      )
    end
    # rubocop:enable Metrics/ParameterLists

    # Create a score for the currently active observation (from OTel span)
    #
    # Extracts observation_id and trace_id from the active OpenTelemetry span.
    #
    # @param name [String] Score name (required)
    # @param value [Numeric, Integer, String] Score value
    # @param comment [String, nil] Optional comment
    # @param metadata [Hash, nil] Optional metadata hash
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical)
    # @return [void]
    # @raise [ArgumentError] if no active span or validation fails
    #
    # @example
    #   Langfuse.observe("operation") do |obs|
    #     client.score_active_observation(name: "accuracy", value: 0.92)
    #   end
    def score_active_observation(name:, value:, comment: nil, metadata: nil, data_type: :numeric)
      @score_client.score_active_observation(
        name: name,
        value: value,
        comment: comment,
        metadata: metadata,
        data_type: data_type
      )
    end

    # Create a score for the currently active trace (from OTel span)
    #
    # Extracts trace_id from the active OpenTelemetry span.
    #
    # @param name [String] Score name (required)
    # @param value [Numeric, Integer, String] Score value
    # @param comment [String, nil] Optional comment
    # @param metadata [Hash, nil] Optional metadata hash
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical)
    # @return [void]
    # @raise [ArgumentError] if no active span or validation fails
    #
    # @example
    #   Langfuse.observe("operation") do |obs|
    #     client.score_active_trace(name: "overall_quality", value: 5)
    #   end
    def score_active_trace(name:, value:, comment: nil, metadata: nil, data_type: :numeric)
      @score_client.score_active_trace(
        name: name,
        value: value,
        comment: comment,
        metadata: metadata,
        data_type: data_type
      )
    end

    # Force flush all queued score events
    #
    # Sends all queued score events to the API immediately.
    #
    # @return [void]
    #
    # @example
    #   client.flush_scores
    def flush_scores
      @score_client.flush
    end

    # Shutdown the client and flush any pending scores
    #
    # Also shuts down the cache if it supports shutdown (e.g., SWR thread pool).
    #
    # @return [void]
    def shutdown
      @score_client.shutdown
      @api_client.shutdown
    end

    # Create a new dataset
    #
    # @param name [String] Dataset name (required)
    # @param description [String, nil] Optional description
    # @param metadata [Hash, nil] Optional metadata hash
    # @return [DatasetClient] The created dataset client
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   dataset = client.create_dataset(name: "my-dataset", description: "QA evaluation set")
    def create_dataset(name:, description: nil, metadata: nil)
      data = api_client.create_dataset(name: name, description: description, metadata: metadata)
      DatasetClient.new(data, client: self)
    end

    # Fetch a dataset by name
    #
    # @param name [String] Dataset name (supports folder paths like "evaluation/qa-dataset")
    # @return [DatasetClient] The dataset client
    # @raise [NotFoundError] if the dataset is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   dataset = client.get_dataset("my-dataset")
    def get_dataset(name)
      data = api_client.get_dataset(name)
      DatasetClient.new(data, client: self)
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
    #   datasets = client.list_datasets(page: 1, limit: 10)
    def list_datasets(page: nil, limit: nil)
      api_client.list_datasets(page: page, limit: limit)
    end

    # List traces in the project
    #
    # @param page [Integer, nil] Optional page number for pagination
    # @param limit [Integer, nil] Optional limit per page
    # @param filters [Hash] Additional filters (user_id, name, session_id, etc.)
    # @return [Array<Hash>] Array of trace hashes
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   traces = client.list_traces(page: 1, limit: 10, name: "my-trace")
    def list_traces(page: nil, limit: nil, **filters)
      api_client.list_traces(page: page, limit: limit, **filters)
    end

    # Fetch a trace by ID
    #
    # @param id [String] Trace ID
    # @return [Hash] The trace data
    # @raise [NotFoundError] if the trace is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   trace = client.get_trace("trace-uuid-123")
    def get_trace(id)
      api_client.get_trace(id)
    end

    # Create a new dataset item
    #
    # @param dataset_name [String] Name of the dataset to add item to (required)
    # @param input [Object, nil] Input data for the item
    # @param expected_output [Object, nil] Expected output for evaluation
    # @param metadata [Hash, nil] Optional metadata
    # @param id [String, nil] Optional ID for upsert behavior
    # @param source_trace_id [String, nil] Link to source trace
    # @param source_observation_id [String, nil] Link to source observation
    # @param status [Symbol, nil] Item status (:active or :archived)
    # @return [DatasetItemClient] The created dataset item client
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   item = client.create_dataset_item(
    #     dataset_name: "my-dataset",
    #     input: { query: "What is Ruby?" },
    #     expected_output: { answer: "A programming language" }
    #   )
    # rubocop:disable Metrics/ParameterLists
    def create_dataset_item(dataset_name:, input: nil, expected_output: nil,
                            metadata: nil, id: nil, source_trace_id: nil,
                            source_observation_id: nil, status: nil)
      data = api_client.create_dataset_item(
        dataset_name: dataset_name, input: input, expected_output: expected_output,
        metadata: metadata, id: id, source_trace_id: source_trace_id,
        source_observation_id: source_observation_id, status: status
      )
      DatasetItemClient.new(data, client: self)
    end
    # rubocop:enable Metrics/ParameterLists

    # Fetch a dataset item by ID
    #
    # @param id [String] Dataset item ID
    # @return [DatasetItemClient] The dataset item client
    # @raise [NotFoundError] if the item is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   item = client.get_dataset_item("item-uuid-123")
    def get_dataset_item(id)
      data = api_client.get_dataset_item(id)
      DatasetItemClient.new(data, client: self)
    end

    # List items in a dataset
    #
    # When page is nil (default), auto-paginates to fetch all items.
    # When page is provided, returns only that single page.
    #
    # @param dataset_name [String] Name of the dataset (required)
    # @param page [Integer, nil] Optional page number for pagination
    # @param limit [Integer, nil] Optional limit per page
    # @param source_trace_id [String, nil] Filter by source trace ID
    # @param source_observation_id [String, nil] Filter by source observation ID
    # @return [Array<DatasetItemClient>] Array of dataset item clients
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example
    #   items = client.list_dataset_items(dataset_name: "my-dataset", limit: 50)
    def list_dataset_items(dataset_name:, page: nil, limit: nil,
                           source_trace_id: nil, source_observation_id: nil)
      filters = { dataset_name: dataset_name, source_trace_id: source_trace_id,
                  source_observation_id: source_observation_id }

      items = if page
                fetch_dataset_items_page(page: page, limit: limit, **filters)
              else
                fetch_all_dataset_items(limit: limit, **filters)
              end

      items.map { |data| DatasetItemClient.new(data, client: self) }
    end

    # Delete a dataset item by ID
    #
    # @param id [String] Dataset item ID
    # @return [nil]
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    # @note 404 responses are treated as success to keep DELETE idempotent across retries
    #
    # @example
    #   client.delete_dataset_item("item-uuid-123")
    def delete_dataset_item(id)
      api_client.delete_dataset_item(id)
      nil
    end

    # Create a dataset run item (link a trace to a dataset item)
    #
    # @param dataset_item_id [String] Dataset item ID (required)
    # @param run_name [String] Run name (required)
    # @param trace_id [String, nil] Trace ID
    # @param observation_id [String, nil] Observation ID
    # @param metadata [Hash, nil] Optional metadata
    # @param run_description [String, nil] Optional run description
    # @return [Hash] The created dataset run item data
    def create_dataset_run_item(dataset_item_id:, run_name:, trace_id: nil,
                                observation_id: nil, metadata: nil, run_description: nil)
      api_client.create_dataset_run_item(
        dataset_item_id: dataset_item_id,
        run_name: run_name,
        trace_id: trace_id,
        observation_id: observation_id,
        metadata: metadata,
        run_description: run_description
      )
    end

    # Run an experiment against local data or a named dataset
    #
    # @param name [String] Experiment/run name (required)
    # @param data [Array<Hash, DatasetItemClient>, nil] Local data items (each Hash with
    #   :input/:expected_output or "input"/"expected_output"; also accepts DatasetItemClient
    #   objects, e.g. when called from {DatasetClient#run_experiment})
    # @param dataset_name [String, nil] Dataset name to fetch items from
    # @param task [Proc] Callable receiving a single argument (the item).
    #   The item is a {DatasetItemClient} (when using dataset_name:) or
    #   {ExperimentItem} (when using data:). Tracing is handled automatically;
    #   use {DatasetItemClient#run} for direct span access.
    # @param description [String, nil] Optional run description
    # @param evaluators [Array<Proc>] Item-level evaluators
    # @param run_evaluators [Array<Proc>] Run-level evaluators
    # @param metadata [Hash, nil] Optional metadata
    # @param run_name [String, nil] Explicit run name (defaults to "name - timestamp")
    # @return [ExperimentResult]
    # rubocop:disable Metrics/ParameterLists
    def run_experiment(name:, task:, data: nil, dataset_name: nil, description: nil,
                       evaluators: [], run_evaluators: [], metadata: nil, run_name: nil)
      raise ArgumentError, "Provide either data: or dataset_name:, not both" if data && dataset_name
      raise ArgumentError, "Provide data: or dataset_name:" unless data || dataset_name

      items = resolve_experiment_items(data, dataset_name)

      ExperimentRunner.new(
        client: self,
        name: name,
        items: items,
        task: task,
        evaluators: evaluators,
        run_evaluators: run_evaluators,
        metadata: metadata,
        description: description,
        run_name: run_name
      ).execute
    end
    # rubocop:enable Metrics/ParameterLists

    private

    attr_reader :score_client

    # Build a project-scoped URL, returning nil if project ID is unavailable
    def project_url(path)
      pid = project_id
      return nil unless pid

      "#{config.base_url}/project/#{pid}/#{path}"
    end

    # Fetch project ID from the API and cache it
    #
    # @return [String, nil] the project ID, or nil on failure
    def fetch_project_id
      data = api_client.get_projects
      @project_id = data.dig("data", 0, "id")
    rescue StandardError
      nil
    ensure
      @project_id_fetched = true
    end

    def fetch_dataset_items_page(page:, limit:, **filters)
      api_client.list_dataset_items(page: page, limit: limit, **filters)
    end

    def fetch_all_dataset_items(limit:, **filters)
      per_page = limit || DATASET_ITEMS_PAGE_SIZE
      first_result = api_client.list_dataset_items_paginated(page: 1, limit: per_page, **filters)
      items = first_result["data"] || []
      total_pages = first_result.dig("meta", "totalPages") || 1

      (2..total_pages).each do |pg|
        result = api_client.list_dataset_items_paginated(page: pg, limit: per_page, **filters)
        items.concat(result["data"] || [])
      end

      items
    end

    def resolve_experiment_items(data, dataset_name)
      return data if data

      list_dataset_items(dataset_name: dataset_name)
    end

    # Check if caching is enabled in configuration
    #
    # @return [Boolean]
    def cache_enabled?
      config.cache_ttl&.positive?
    end

    # Create a cache instance based on configuration
    #
    # @return [PromptCache, RailsCacheAdapter]
    def create_cache
      case config.cache_backend
      when :memory
        create_memory_cache
      when :rails
        create_rails_cache_adapter
      else
        raise ConfigurationError, "Unknown cache backend: #{config.cache_backend}"
      end
    end

    # Create in-memory cache with SWR support if enabled
    #
    # @return [PromptCache]
    def create_memory_cache
      PromptCache.new(
        ttl: config.cache_ttl,
        max_size: config.cache_max_size,
        stale_ttl: config.normalized_stale_ttl,
        refresh_threads: config.cache_refresh_threads,
        logger: config.logger
      )
    end

    def create_rails_cache_adapter
      RailsCacheAdapter.new(
        ttl: config.cache_ttl,
        lock_timeout: config.cache_lock_timeout,
        stale_ttl: config.normalized_stale_ttl,
        refresh_threads: config.cache_refresh_threads,
        logger: config.logger
      )
    end

    # Build the appropriate prompt client based on prompt type
    #
    # @param prompt_data [Hash] The prompt data from API
    # @return [TextPromptClient, ChatPromptClient]
    # @raise [ApiError] if prompt type is unknown
    def build_prompt_client(prompt_data)
      type = prompt_data["type"]

      case type
      when "text"
        TextPromptClient.new(prompt_data)
      when "chat"
        ChatPromptClient.new(prompt_data)
      else
        raise ApiError, "Unknown prompt type: #{type}"
      end
    end

    # Build a fallback prompt client from fallback data
    #
    # @param name [String] The prompt name
    # @param fallback [String, Array] The fallback prompt content
    # @param type [Symbol] The prompt type (:text or :chat)
    # @return [TextPromptClient, ChatPromptClient]
    # @raise [ArgumentError] if type is invalid
    def build_fallback_prompt_client(name, fallback, type)
      validate_prompt_type!(type)

      # Create minimal prompt data structure
      prompt_data = {
        "name" => name,
        "version" => 0,
        "type" => type.to_s,
        "prompt" => fallback,
        "labels" => [],
        "tags" => ["fallback"],
        "config" => {}
      }

      case type
      when :text
        TextPromptClient.new(prompt_data)
      when :chat
        ChatPromptClient.new(prompt_data)
      end
    end

    # Validate prompt type parameter
    #
    # @param type [Symbol] The type to validate
    # @raise [ArgumentError] if type is invalid
    def validate_prompt_type!(type)
      valid_types = %i[text chat]
      return if valid_types.include?(type)

      raise ArgumentError, "Invalid type: #{type}. Must be :text or :chat"
    end

    # Validate prompt content matches the declared type
    #
    # @param prompt [String, Array] The prompt content
    # @param type [Symbol] The declared type
    # @raise [ArgumentError] if content doesn't match type
    def validate_prompt_content!(prompt, type)
      case type
      when :text
        raise ArgumentError, "Text prompt must be a String" unless prompt.is_a?(String)
      when :chat
        raise ArgumentError, "Chat prompt must be an Array" unless prompt.is_a?(Array)
      end
    end

    # Normalize prompt content for API request
    #
    # Converts Ruby symbol keys to string keys for chat messages
    #
    # @param prompt [String, Array] The prompt content
    # @param type [Symbol] The prompt type
    # @return [String, Array] Normalized content
    def normalize_prompt_content(prompt, type)
      return prompt if type == :text

      # Normalize chat messages to use string keys
      prompt.map do |message|
        # Convert all keys to symbols first, then extract
        normalized = message.transform_keys do |k|
          k.to_sym
        rescue StandardError
          k
        end
        {
          "role" => normalized[:role]&.to_s,
          "content" => normalized[:content]
        }
      end
    end
  end
  # rubocop:enable Metrics/ClassLength
end
