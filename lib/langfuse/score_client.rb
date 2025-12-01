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
    attr_reader :api_client, :config, :logger

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

      start_flush_timer
    end

    # Create a score event and queue it for batching
    #
    # @param name [String] Score name (required)
    # @param value [Numeric, Integer, String] Score value (type depends on data_type)
    # @param trace_id [String, nil] Trace ID to associate with the score
    # @param observation_id [String, nil] Observation ID to associate with the score
    # @param comment [String, nil] Optional comment
    # @param metadata [Hash, nil] Optional metadata hash
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical)
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
    # rubocop:disable Metrics/ParameterLists
    def create(name:, value:, trace_id: nil, observation_id: nil, comment: nil, metadata: nil,
               data_type: :numeric)
      validate_name(name)
      normalized_value = normalize_value(value, data_type)
      data_type_str = Types::SCORE_DATA_TYPES[data_type] || raise(ArgumentError, "Invalid data_type: #{data_type}")

      event = build_score_event(
        name: name,
        value: normalized_value,
        trace_id: trace_id,
        observation_id: observation_id,
        comment: comment,
        metadata: metadata,
        data_type: data_type_str
      )

      @queue << event

      # Trigger flush if batch size reached
      flush if @queue.size >= config.batch_size
    rescue StandardError => e
      logger.error("Langfuse score creation failed: #{e.message}")
      raise
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
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical)
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

    # Build a score event hash for ingestion API
    #
    # @param name [String] Score name
    # @param value [Object] Normalized score value
    # @param trace_id [String, nil] Trace ID
    # @param observation_id [String, nil] Observation ID
    # @param comment [String, nil] Comment
    # @param metadata [Hash, nil] Metadata
    # @param data_type [String] Data type string (NUMERIC, BOOLEAN, CATEGORICAL)
    # @return [Hash] Event hash
    # rubocop:disable Metrics/ParameterLists
    def build_score_event(name:, value:, trace_id:, observation_id:, comment:, metadata:, data_type:)
      body = {
        id: SecureRandom.uuid,
        name: name,
        value: value,
        dataType: data_type
      }
      body[:traceId] = trace_id if trace_id
      body[:observationId] = observation_id if observation_id
      body[:comment] = comment if comment
      body[:metadata] = metadata if metadata

      {
        id: SecureRandom.uuid,
        type: "score-create",
        timestamp: Time.now.utc.iso8601(3),
        body: body
      }
    end
    # rubocop:enable Metrics/ParameterLists

    # Normalize and validate score value based on data type
    #
    # @param value [Object] Raw score value
    # @param data_type [Symbol] Data type symbol
    # @return [Object] Normalized value
    # @raise [ArgumentError] if value doesn't match data type
    # rubocop:disable Metrics/CyclomaticComplexity
    def normalize_value(value, data_type)
      case data_type
      when :numeric
        raise ArgumentError, "Numeric value must be Numeric, got #{value.class}" unless value.is_a?(Numeric)

        value
      when :boolean
        case value
        when true, 1
          1
        when false, 0
          0
        else
          raise ArgumentError, "Boolean value must be true/false or 0/1, got #{value.inspect}"
        end
      when :categorical
        raise ArgumentError, "Categorical value must be a String, got #{value.class}" unless value.is_a?(String)

        value
      else
        raise ArgumentError, "Invalid data_type: #{data_type}"
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity

    # Validate score name
    #
    # @param name [String] Score name
    # @raise [ArgumentError] if name is invalid
    def validate_name(name)
      raise ArgumentError, "name is required" if name.nil?
      raise ArgumentError, "name must be a String" unless name.is_a?(String)
      raise ArgumentError, "name is required" if name.empty?
    end

    # Extract trace_id and observation_id from active OTel span
    #
    # @return [Hash] Hash with :trace_id and :observation_id (may be nil)
    def extract_ids_from_active_span
      span = OpenTelemetry::Trace.current_span
      return { trace_id: nil, observation_id: nil } unless span&.recording?

      {
        trace_id: span.context.trace_id.unpack1("H*"),
        observation_id: span.context.span_id.unpack1("H*")
      }
    end

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
