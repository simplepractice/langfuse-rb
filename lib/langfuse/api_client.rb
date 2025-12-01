# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "base64"
require "json"

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
  # rubocop:disable Metrics/ClassLength
  class ApiClient
    attr_reader :public_key, :secret_key, :base_url, :timeout, :logger, :cache

    # Initialize a new API client
    #
    # @param public_key [String] Langfuse public API key
    # @param secret_key [String] Langfuse secret API key
    # @param base_url [String] Base URL for Langfuse API
    # @param timeout [Integer] HTTP request timeout in seconds
    # @param logger [Logger] Logger instance for debugging
    # @param cache [PromptCache, nil] Optional cache for prompt responses
    def initialize(public_key:, secret_key:, base_url:, timeout: 5, logger: nil, cache: nil)
      @public_key = public_key
      @secret_key = secret_key
      @base_url = base_url
      @timeout = timeout
      @logger = logger || Logger.new($stdout, level: Logger::WARN)
      @cache = cache
    end

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
      params = {}
      params[:page] = page if page
      params[:limit] = limit if limit

      path = "/api/public/v2/prompts"
      response = connection.get(path, params)
      result = handle_response(response)

      # API returns { data: [...], meta: {...} }
      result["data"] || []
    rescue Faraday::RetriableResponse => e
      logger.error("Faraday error: Retries exhausted - #{e.response.status}")
      handle_response(e.response)
    rescue Faraday::Error => e
      logger.error("Faraday error: #{e.message}")
      raise ApiError, "HTTP request failed: #{e.message}"
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
    # @return [Hash] The prompt data
    # @raise [ArgumentError] if both version and label are provided
    # @raise [NotFoundError] if the prompt is not found
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    def get_prompt(name, version: nil, label: nil)
      raise ArgumentError, "Cannot specify both version and label" if version && label

      cache_key = PromptCache.build_key(name, version: version, label: label)

      # Use distributed lock if cache supports it (Rails.cache backend)
      if cache.respond_to?(:fetch_with_lock)
        cache.fetch_with_lock(cache_key) do
          fetch_prompt_from_api(name, version: version, label: label)
        end
      elsif cache
        # In-memory cache - use simple get/set pattern
        cached_data = cache.get(cache_key)
        return cached_data if cached_data

        prompt_data = fetch_prompt_from_api(name, version: version, label: label)
        cache.set(cache_key, prompt_data)
        prompt_data
      else
        # No cache - fetch directly
        fetch_prompt_from_api(name, version: version, label: label)
      end
    end

    # Send a batch of events to the Langfuse ingestion API
    #
    # Sends events (scores, traces, observations) to the ingestion endpoint.
    # Retries transient errors (429, 503, 504, network errors) with exponential backoff.
    # Batch operations are idempotent (events have unique IDs), so retries are safe.
    #
    # @param events [Array<Hash>] Array of event hashes to send
    # @return [void]
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

      path = "/api/public/ingestion"
      payload = { batch: events }

      response = connection.post(path, payload)
      handle_batch_response(response)
    rescue Faraday::RetriableResponse => e
      # Retry middleware exhausted all retries - handle the final response
      logger.error("Langfuse batch send failed: Retries exhausted - #{e.response.status}")
      handle_batch_response(e.response)
    rescue Faraday::Error => e
      logger.error("Langfuse batch send failed: #{e.message}")
      raise ApiError, "Batch send failed: #{e.message}"
    end

    private

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
      params = build_prompt_params(version: version, label: label)
      path = "/api/public/v2/prompts/#{name}"

      response = connection.get(path, params)
      handle_response(response)
    rescue Faraday::RetriableResponse => e
      # Retry middleware exhausted all retries - handle the final response
      logger.error("Faraday error: Retries exhausted - #{e.response.status}")
      handle_response(e.response)
    rescue Faraday::Error => e
      logger.error("Faraday error: #{e.message}")
      raise ApiError, "HTTP request failed: #{e.message}"
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
    # - Retries GET requests and POST requests to batch endpoint (idempotent operations)
    # - Retries on: 429 (rate limit), 503 (service unavailable), 504 (gateway timeout)
    # - Does NOT retry on: 4xx errors (except 429), 5xx errors (except 503, 504)
    #
    # @return [Hash] Retry options for Faraday::Retry middleware
    def retry_options
      {
        max: 2,
        interval: 0.05,
        backoff_factor: 2,
        methods: %i[get post],
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

    # Build query parameters for prompt request
    #
    # @param version [Integer, nil] Optional version number
    # @param label [String, nil] Optional label
    # @return [Hash] Query parameters
    def build_prompt_params(version: nil, label: nil)
      params = {}
      params[:version] = version if version
      params[:label] = label if label
      params
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
      when 200
        response.body
      when 401
        raise UnauthorizedError, "Authentication failed. Check your API keys."
      when 404
        raise NotFoundError, "Prompt not found"
      else
        error_message = extract_error_message(response)
        raise ApiError, "API request failed (#{response.status}): #{error_message}"
      end
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
# rubocop:enable Metrics/ClassLength
