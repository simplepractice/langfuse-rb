# frozen_string_literal: true

require "securerandom"
require "opentelemetry/trace"

module Langfuse
  # Client for creating and batching Langfuse scores
  #
  # Handles thread-safe queuing, batching, and sending of score events
  # to the Langfuse ingestion API. Scores are batched and sent automatically
  # based on batch_size and flush_interval configuration.
  #
  # @example Basic usage
  #   score_client = ScoreClient.new(api_client: api_client, config: config)
  #   score_client.create(name: "quality", value: 0.85, trace_id: "abc123...")
  #
  # @example With OTel integration
  #   Langfuse.observe("operation") do |obs|
  #     score_client.score_active_observation(name: "accuracy", value: 0.92)
  #   end
  #
  # @api private
  # rubocop:disable Metrics/ClassLength
  class ScoreClient
    # @return [ApiClient] The API client for sending batches
    attr_reader :api_client

    # @return [Config] Configuration object
    attr_reader :config

    # @return [Logger] Logger instance
    attr_reader :logger

    HEX_TRACE_ID_PATTERN = /\A[0-9a-f]{32}\z/

    # Validate and normalize the attributes every score shares.
    #
    # Stateless so callers can reject bad arguments before a client exists.
    # Scores dropped because Langfuse is unconfigured still run this, keeping
    # argument errors visible in environments without credentials.
    #
    # @api private
    # @param name [String] Score name
    # @param value [Numeric, Integer, String] Raw score value
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical, :text, :correction)
    # @return [Array(Object, String)] Normalized value and API data type string
    # @raise [ArgumentError] if the name, value, or data type is invalid
    def self.normalize_attributes!(name:, value:, data_type:)
      validate_name(name)
      normalized_value = ScoreValue.normalize(value, data_type)
      data_type_str = Types::SCORE_DATA_TYPES[data_type] || raise(ArgumentError, "Invalid data_type: #{data_type}")

      [normalized_value, data_type_str]
    end

    # Initialize a new ScoreClient
    #
    # @param api_client [ApiClient] The API client for sending batches
    # @param config [Config] Configuration object with batch_size and flush_interval
    def initialize(api_client:, config:)
      @api_client = api_client
      @config = config
      @logger = config.logger
      @queue = Queue.new
      @mutex = Mutex.new
      @flush_thread = nil
      @shutdown = false
      # Match the immutable tracing setup contract: once this client exists, later config
      # mutations must not change score sampling without rebuilding the client.
      @score_sampler = Sampling.build_sampler(config.sample_rate)

      start_flush_timer
    end

    # Create a score event and queue it for batching
    #
    # @param name [String] Score name (required)
    # @param value [Numeric, Integer, String] Score value (type depends on data_type)
    # @param id [String, nil] Score ID; use a stable value as an idempotency key
    # @param trace_id [String, nil] Trace ID to associate with the score
    # @param session_id [String, nil] Session ID to associate with the score
    # @param observation_id [String, nil] Observation ID to associate with the score
    # @param comment [String, nil] Optional comment
    # @param metadata [Hash, nil] Optional metadata hash
    # @param environment [String, nil] Optional environment
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical, :text, :correction)
    # @param dataset_run_id [String, nil] Optional dataset run ID to associate with the score
    # @param config_id [String, nil] Optional score config ID
    # @return [void]
    # @raise [ArgumentError] if validation fails
    #
    # @example Numeric score
    #   create(name: "quality", value: 0.85, trace_id: "abc123", data_type: :numeric)
    #
    # @example Boolean score
    #   create(name: "passed", value: true, trace_id: "abc123", data_type: :boolean)
    #
    # @example Categorical score
    #   create(name: "category", value: "high", trace_id: "abc123", data_type: :categorical)
    #
    # @example Text score (1 to 500 characters)
    #   create(name: "reviewer_notes", value: "Helpful but verbose", trace_id: "abc123", data_type: :text)
    #
    # @example Corrected output (conventionally named "output")
    #   create(name: "output", value: "The corrected output", trace_id: "abc123",
    #          observation_id: "def456", data_type: :correction)
    # rubocop:disable Metrics/ParameterLists
    def create(name:, value:, id: nil, trace_id: nil, session_id: nil, observation_id: nil, comment: nil,
               metadata: nil, environment: nil, data_type: :numeric, dataset_run_id: nil, config_id: nil)
      score = build_score_body(
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

      return unless enqueue_trace_linked_score?(trace_id)

      @queue << build_score_event(score)
      flush if @queue.size >= config.batch_size
    rescue StandardError => e
      logger.error("Langfuse score creation failed: #{e.message}")
      raise
    end
    # rubocop:enable Metrics/ParameterLists

    # Create a score immediately through the Scores API.
    #
    # {#create} is fire-and-forget — it queues the event and reports nothing
    # about whether it was actually delivered, matching how this SDK's
    # tracing already works. That fits scoring inline from a still-open span
    # (see {#score_active_observation}/{#score_active_trace}), but not a
    # standalone verdict arriving out-of-band (e.g. user feedback landing in
    # a request unrelated to the turn it's scoring). Pass a stable +id+ when
    # the caller may retry after an ambiguous network failure.
    #
    # @param name [String] Score name (required)
    # @param value [Numeric, Integer, String] Score value (type depends on data_type)
    # @param id [String, nil] Score ID; use a stable value as an idempotency key
    # @param trace_id [String, nil] Trace ID to associate with the score
    # @param session_id [String, nil] Session ID to associate with the score
    # @param observation_id [String, nil] Observation ID to associate with the score
    # @param comment [String, nil] Optional comment
    # @param metadata [Hash, nil] Optional metadata hash
    # @param environment [String, nil] Optional environment
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical, :text, :correction)
    # @param dataset_run_id [String, nil] Optional dataset run ID to associate with the score
    # @param config_id [String, nil] Optional score config ID
    # @return [String] ID of the created score
    # @raise [ArgumentError] if validation fails
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] if the API request fails
    #
    # @example Create a score with an idempotency key
    #   score_client.create!(id: "feedback-abc123", name: "quality", value: 0.85, trace_id: "abc123")
    # rubocop:disable Metrics/ParameterLists
    def create!(name:, value:, id: nil, trace_id: nil, session_id: nil, observation_id: nil, comment: nil,
                metadata: nil, environment: nil, data_type: :numeric, dataset_run_id: nil, config_id: nil)
      score = build_score_body(
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

      api_client.create_score(payload: score)
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
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical, :text, :correction)
    # @return [void]
    # @raise [ArgumentError] if no active span or validation fails
    #
    # @example
    #   Langfuse.observe("operation") do |obs|
    #     score_client.score_active_observation(name: "accuracy", value: 0.92)
    #   end
    def score_active_observation(name:, value:, comment: nil, metadata: nil, data_type: :numeric)
      ids = extract_ids_from_active_span
      raise ArgumentError, "No active OpenTelemetry span found" unless ids[:observation_id]

      create(
        name: name,
        value: value,
        trace_id: ids[:trace_id],
        observation_id: ids[:observation_id],
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
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical, :text, :correction)
    # @return [void]
    # @raise [ArgumentError] if no active span or validation fails
    #
    # @example
    #   Langfuse.observe("operation") do |obs|
    #     score_client.score_active_trace(name: "overall_quality", value: 5)
    #   end
    def score_active_trace(name:, value:, comment: nil, metadata: nil, data_type: :numeric)
      ids = extract_ids_from_active_span
      raise ArgumentError, "No active OpenTelemetry span found" unless ids[:trace_id]

      create(
        name: name,
        value: value,
        trace_id: ids[:trace_id],
        comment: comment,
        metadata: metadata,
        data_type: data_type
      )
    end

    # Force flush all queued score events
    #
    # Sends all queued events to the API immediately.
    #
    # @return [void]
    def flush
      return if @queue.empty?

      events = []
      @queue.size.times do
        events << @queue.pop(true)
      rescue StandardError
        nil
      end
      events.compact!

      return if events.empty?

      send_batch(events)
    rescue StandardError => e
      logger.error("Langfuse score flush failed: #{e.message}")
      # Don't raise - silent error handling for batch operations
    end

    # Shutdown the score client and flush remaining events
    #
    # Stops the flush timer thread and sends any remaining queued events.
    #
    # @return [void]
    def shutdown
      @mutex.synchronize do
        return if @shutdown

        @shutdown = true
        stop_flush_timer
        flush
      end
    end

    private

    # Validate score inputs and build the canonical API body.
    #
    # @param name [String] Score name
    # @param value [Numeric, Integer, String] Raw score value (type depends on data_type)
    # @param id [String, nil] Score ID
    # @param trace_id [String, nil] Trace ID
    # @param session_id [String, nil] Session ID
    # @param observation_id [String, nil] Observation ID
    # @param comment [String, nil] Comment
    # @param metadata [Hash, nil] Metadata
    # @param environment [String, nil] Environment
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical, :text, :correction)
    # @param dataset_run_id [String, nil] Dataset run ID
    # @param config_id [String, nil] Score config ID
    # @return [Hash] Score attributes in API format
    # @raise [ArgumentError] if validation fails
    # rubocop:disable Metrics/ParameterLists
    def build_score_body(name:, value:, id:, trace_id:, session_id:, observation_id:, comment:, metadata:,
                         environment:, data_type:, dataset_run_id: nil, config_id: nil)
      normalized_value, data_type_str = self.class.normalize_attributes!(
        name: name, value: value, data_type: data_type
      )
      validate_correction_subject!(data_type:, trace_id:, session_id:, dataset_run_id:, config_id:)

      {
        id: id || SecureRandom.uuid,
        name: name,
        value: normalized_value,
        dataType: data_type_str,
        traceId: trace_id,
        sessionId: session_id,
        observationId: observation_id,
        comment: comment,
        metadata: metadata,
        environment: environment,
        datasetRunId: dataset_run_id,
        configId: config_id
      }.compact
    end
    # rubocop:enable Metrics/ParameterLists

    def build_score_event(score)
      { id: SecureRandom.uuid, type: "score-create", timestamp: Time.now.utc.iso8601(3), body: score }
    end

    def validate_correction_subject!(data_type:, trace_id:, session_id:, dataset_run_id:, config_id:)
      return unless data_type == :correction
      return if trace_id.is_a?(String) && !trace_id.empty? && !session_id && !dataset_run_id && !config_id

      raise ArgumentError,
            "Correction scores require trace_id and cannot use session_id, dataset_run_id, or config_id"
    end

    # Validate score name
    #
    # @param name [String] Score name
    # @raise [ArgumentError] if name is invalid
    def self.validate_name(name)
      raise ArgumentError, "name is required" if name.nil?
      raise ArgumentError, "name must be a String" unless name.is_a?(String)
      raise ArgumentError, "name is required" if name.empty?
    end
    private_class_method :validate_name

    # Extract trace_id and observation_id from active OTel span
    #
    # @return [Hash] Hash with :trace_id and :observation_id (may be nil)
    def extract_ids_from_active_span
      span = OpenTelemetry::Trace.current_span
      span_context = span&.context
      return { trace_id: nil, observation_id: nil } unless span_context&.valid?

      {
        trace_id: span_context.trace_id.unpack1("H*"),
        observation_id: span_context.span_id.unpack1("H*")
      }
    end

    # Score sampling is decided purely by the configured sampler on the trace_id hash,
    # matching langfuse-python. Non-hex trace ids and session/dataset-only scores bypass sampling.
    def enqueue_trace_linked_score?(trace_id)
      return true if trace_id.nil?
      return true unless HEX_TRACE_ID_PATTERN.match?(trace_id)

      sampler = score_sampler
      return true if sampler.nil?
      return true unless sampler.respond_to?(:should_sample?)

      sample_result = sampler.should_sample?(
        trace_id: [trace_id].pack("H*"),
        parent_context: nil,
        links: [],
        name: "score",
        kind: OpenTelemetry::Trace::SpanKind::INTERNAL,
        attributes: {}
      )
      sample_result.sampled?
    rescue StandardError => e
      logger.warn("Langfuse score sampling fallback for trace_id=#{trace_id}: #{e.message}")
      true
    end

    # Sampler is pinned at ScoreClient construction to match the "sample_rate requires reset!"
    # contract and to keep each client's sampling scoped to its own config.
    attr_reader :score_sampler

    # Send a batch of events to the API
    #
    # @param events [Array<Hash>] Array of event hashes
    # @return [void]
    def send_batch(events)
      api_client.send_batch(events)
    rescue StandardError => e
      logger.error("Langfuse score batch send failed: #{e.message}")
      # Don't raise - silent error handling
    end

    # Start the background flush timer thread
    #
    # @return [void]
    def start_flush_timer
      return if config.flush_interval.nil? || config.flush_interval <= 0

      @flush_thread = Thread.new do
        loop do
          sleep(config.flush_interval)
          break if @shutdown

          flush
        rescue StandardError => e
          logger.error("Langfuse score flush timer error: #{e.message}")
        end
      end
      @flush_thread.abort_on_exception = false
      @flush_thread.name = "langfuse-score-flush"
    end

    # Stop the flush timer thread
    #
    # @return [void]
    def stop_flush_timer
      return unless @flush_thread&.alive?

      @flush_thread.kill
      @flush_thread.join(1) # Wait up to 1 second for thread to finish
    end
  end
end
# rubocop:enable Metrics/ClassLength
