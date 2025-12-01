# frozen_string_literal: true

require_relative "langfuse/version"
require_relative "langfuse/types"

# Langfuse Ruby SDK
#
# Official Ruby SDK for Langfuse, providing LLM tracing, observability,
# and prompt management capabilities.
#
# @example Global configuration (Rails initializer)
#   Langfuse.configure do |config|
#     config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
#     config.secret_key = ENV['LANGFUSE_SECRET_KEY']
#     config.cache_ttl = 120
#   end
#
# @example Using the global client
#   client = Langfuse.client
#   prompt = client.get_prompt("greeting")
#
module Langfuse
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ApiError < Error; end
  class NotFoundError < ApiError; end
  class UnauthorizedError < ApiError; end
end

require_relative "langfuse/config"
require_relative "langfuse/prompt_cache"
require_relative "langfuse/rails_cache_adapter"
require_relative "langfuse/cache_warmer"
require_relative "langfuse/api_client"
require_relative "langfuse/otel_setup"
require_relative "langfuse/otel_attributes"
require_relative "langfuse/propagation"
require_relative "langfuse/span_processor"
require_relative "langfuse/observations"
require_relative "langfuse/score_client"
require_relative "langfuse/text_prompt_client"
require_relative "langfuse/chat_prompt_client"
require_relative "langfuse/client"

# rubocop:disable Metrics/ModuleLength
module Langfuse
  # rubocop:disable Metrics/ClassLength
  class << self
    attr_writer :configuration

    # Returns the global configuration object
    #
    # @return [Config] the global configuration
    def configuration
      @configuration ||= Config.new
    end

    # Configure Langfuse globally
    #
    # @yield [Config] the configuration object
    # @return [Config] the configured configuration
    #
    # @example
    #   Langfuse.configure do |config|
    #     config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
    #     config.secret_key = ENV['LANGFUSE_SECRET_KEY']
    #   end
    def configure
      yield(configuration)

      # Auto-initialize OpenTelemetry
      OtelSetup.setup(configuration)

      configuration
    end

    # Returns the global singleton client
    #
    # @return [Client] the global client instance
    def client
      @client ||= Client.new(configuration)
    end

    # Shutdown Langfuse and flush any pending traces and scores
    #
    # Call this when shutting down your application to ensure
    # all traces and scores are sent to Langfuse.
    #
    # @param timeout [Integer] Timeout in seconds
    # @return [void]
    #
    # @example In a Rails initializer or shutdown hook
    #   at_exit { Langfuse.shutdown }
    #
    def shutdown(timeout: 30)
      client.shutdown if @client
      OtelSetup.shutdown(timeout: timeout)
    end

    # Force flush all pending traces
    #
    # @param timeout [Integer] Timeout in seconds
    # @return [void]
    def force_flush(timeout: 30)
      OtelSetup.force_flush(timeout: timeout)
    end

    # Propagate trace-level attributes to all spans created within this context.
    #
    # This method sets attributes on the currently active span AND automatically
    # propagates them to all new child spans created within the block. This is the
    # recommended way to set trace-level attributes like user_id, session_id, and metadata
    # dimensions that should be consistently applied across all observations in a trace.
    #
    # **IMPORTANT**: Call this as early as possible within your trace/workflow. Only the
    # currently active span and spans created after entering this context will have these
    # attributes. Pre-existing spans will NOT be retroactively updated.
    #
    # @param user_id [String, nil] User identifier (≤200 characters)
    # @param session_id [String, nil] Session identifier (≤200 characters)
    # @param metadata [Hash<String, String>, nil] Additional metadata (all values ≤200 characters)
    # @param version [String, nil] Version identifier (≤200 characters)
    # @param tags [Array<String>, nil] List of tags (each ≤200 characters)
    # @param as_baggage [Boolean] If true, propagates via OpenTelemetry baggage for cross-service propagation
    # @yield Block within which attributes are propagated
    # @return [Object] The result of the block
    #
    # @example Basic usage
    #   Langfuse.propagate_attributes(user_id: "user_123", session_id: "session_abc") do
    #     Langfuse.observe("operation") do |span|
    #       # Current span has user_id and session_id
    #       span.start_observation("child") do |child|
    #         # Child span inherits user_id and session_id
    #       end
    #     end
    #   end
    #
    # @example With metadata and tags
    #   Langfuse.propagate_attributes(
    #     user_id: "user_123",
    #     metadata: { environment: "production", region: "us-east" },
    #     tags: ["api", "v2"]
    #   ) do
    #     # All spans inherit these attributes
    #   end
    #
    # @example Cross-service propagation
    #   Langfuse.propagate_attributes(
    #     user_id: "user_123",
    #     as_baggage: true
    #   ) do
    #     # Attributes propagate via HTTP headers
    #   end
    def propagate_attributes(user_id: nil, session_id: nil, metadata: nil, version: nil, tags: nil,
                             as_baggage: false, &)
      Propagation.propagate_attributes(
        user_id: user_id,
        session_id: session_id,
        metadata: metadata,
        version: version,
        tags: tags,
        as_baggage: as_baggage,
        &
      )
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
    #   Langfuse.create_score(name: "quality", value: 0.85, trace_id: "abc123")
    #
    # @example Boolean score
    #   Langfuse.create_score(name: "passed", value: true, trace_id: "abc123", data_type: :boolean)
    #
    # @example Categorical score
    #   Langfuse.create_score(name: "category", value: "high", trace_id: "abc123", data_type: :categorical)
    # rubocop:disable Metrics/ParameterLists
    def create_score(name:, value:, trace_id: nil, observation_id: nil, comment: nil, metadata: nil,
                     data_type: :numeric)
      client.create_score(
        name: name,
        value: value,
        trace_id: trace_id,
        observation_id: observation_id,
        comment: comment,
        metadata: metadata,
        data_type: data_type
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
    #     Langfuse.score_active_observation(name: "accuracy", value: 0.92)
    #   end
    def score_active_observation(name:, value:, comment: nil, metadata: nil, data_type: :numeric)
      client.score_active_observation(
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
    #     Langfuse.score_active_trace(name: "overall_quality", value: 5)
    #   end
    def score_active_trace(name:, value:, comment: nil, metadata: nil, data_type: :numeric)
      client.score_active_trace(
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
    #   Langfuse.flush_scores
    def flush_scores
      client.flush_scores if @client
    end

    # Reset global configuration and client (useful for testing)
    #
    # @return [void]
    def reset!
      client.shutdown if @client
      OtelSetup.shutdown(timeout: 5) if OtelSetup.initialized?
      @configuration = nil
      @client = nil
    rescue StandardError
      # Ignore shutdown errors during reset (e.g., in tests)
      @configuration = nil
      @client = nil
    end

    # Creates a new observation (root or child)
    #
    # This is the module-level factory method that creates observations of any type.
    # It can create root observations (when parent_span_context is nil) or child
    # observations (when parent_span_context is provided).
    #
    # @param name [String] Descriptive name for the observation
    # @param attrs [Hash, Types::SpanAttributes, Types::GenerationAttributes, nil] Observation attributes
    # @param as_type [Symbol, String] Observation type (:span, :generation, :event, etc.)
    # @param parent_span_context [OpenTelemetry::Trace::SpanContext, nil] Parent span context for child observations
    # @param start_time [Time, Integer, nil] Optional start time (Time object or Unix timestamp in nanoseconds)
    # @param skip_validation [Boolean] Skip validation (for internal use). Defaults to false.
    # @return [BaseObservation] The observation wrapper (Span, Generation, or Event)
    #
    # @example Create root span
    #   span = Langfuse.start_observation("root-operation", { input: {...} })
    #
    # @example Create child generation
    #   child = Langfuse.start_observation("llm-call", { model: "gpt-4" },
    #                                       as_type: :generation,
    #                                       parent_span_context: parent.otel_span.context)
    def start_observation(name, attrs = {}, as_type: :span, parent_span_context: nil, start_time: nil,
                          skip_validation: false)
      type_str = as_type.to_s

      unless skip_validation || valid_observation_type?(as_type)
        valid_types = OBSERVATION_TYPES.values.sort.join(", ")
        raise ArgumentError, "Invalid observation type: #{type_str}. Valid types: #{valid_types}"
      end

      otel_tracer = otel_tracer()
      otel_span = create_otel_span(
        name: name,
        start_time: start_time,
        parent_span_context: parent_span_context,
        otel_tracer: otel_tracer
      )

      # Serialize attributes
      # Only set attributes if span is still recording (should always be true here, but guard for safety)
      if otel_span.recording?
        otel_attrs = OtelAttributes.create_observation_attributes(type_str, attrs.to_h)
        otel_attrs.each { |key, value| otel_span.set_attribute(key, value) }
      end

      # Wrap in appropriate class
      observation = wrap_otel_span(otel_span, type_str, otel_tracer, attributes: attrs)

      # Events auto-end immediately when created
      observation.end if type_str == OBSERVATION_TYPES[:event]

      observation
    end

    # User-facing convenience method for creating root observations
    #
    # @param name [String] Descriptive name for the observation
    # @param attrs [Hash] Observation attributes (optional positional or keyword)
    # @param as_type [Symbol, String] Observation type (:span, :generation, :event, etc.)
    # @yield [observation] Optional block that receives the observation object
    # @yieldparam observation [BaseObservation] The observation object
    # @return [BaseObservation, Object] The observation (or block return value if block given)
    #
    # @example Block-based API (auto-ends)
    #   Langfuse.observe("operation") do |obs|
    #     result = perform_operation
    #     obs.update(output: result)
    #   end
    #
    # @example Stateful API (manual end)
    #   obs = Langfuse.observe("operation", input: { data: "test" })
    #   obs.update(output: { result: "success" })
    #   obs.end
    def observe(name, attrs = {}, as_type: :span, **kwargs, &block)
      # Merge positional attrs and keyword kwargs
      merged_attrs = attrs.to_h.merge(kwargs)
      observation = start_observation(name, merged_attrs, as_type: as_type)

      if block
        # Block-based API: auto-ends when block completes
        # Set context and execute block
        current_context = OpenTelemetry::Context.current
        result = OpenTelemetry::Context.with_current(
          OpenTelemetry::Trace.context_with_span(observation.otel_span, parent_context: current_context)
        ) do
          block.call(observation)
        end
        # Only end if not already ended (events auto-end in start_observation)
        observation.end unless as_type.to_s == OBSERVATION_TYPES[:event]
        result
      else
        # Stateful API - return observation
        # Events already auto-ended in start_observation
        observation
      end
    end

    # Registry mapping observation type strings to their wrapper classes
    OBSERVATION_TYPE_REGISTRY = {
      OBSERVATION_TYPES[:generation] => Generation,
      OBSERVATION_TYPES[:embedding] => Embedding,
      OBSERVATION_TYPES[:event] => Event,
      OBSERVATION_TYPES[:agent] => Agent,
      OBSERVATION_TYPES[:tool] => Tool,
      OBSERVATION_TYPES[:chain] => Chain,
      OBSERVATION_TYPES[:retriever] => Retriever,
      OBSERVATION_TYPES[:evaluator] => Evaluator,
      OBSERVATION_TYPES[:guardrail] => Guardrail,
      OBSERVATION_TYPES[:span] => Span
    }.freeze

    private

    # Validates that an observation type is valid
    #
    # Checks if the provided type (symbol or string) matches a valid observation type
    # in the OBSERVATION_TYPES constant.
    #
    # @param type [Symbol, String, Object] The observation type to validate
    # @return [Boolean] true if valid, false otherwise
    #
    # @example
    #   valid_observation_type?(:span)      # => true
    #   valid_observation_type?("span")     # => true
    #   valid_observation_type?(:invalid)   # => false
    #   valid_observation_type?(nil)        # => false
    def valid_observation_type?(type)
      return false unless type.respond_to?(:to_sym)

      OBSERVATION_TYPES.key?(type.to_sym)
    rescue TypeError
      false
    end

    # Gets the OpenTelemetry tracer for Langfuse
    #
    # @return [OpenTelemetry::SDK::Trace::Tracer] The OTel tracer
    def otel_tracer
      OpenTelemetry.tracer_provider.tracer("langfuse-rb", Langfuse::VERSION)
    end

    # Creates an OpenTelemetry span (root or child)
    #
    # @param name [String] Span name
    # @param start_time [Time, Integer, nil] Optional start time
    # @param parent_span_context [OpenTelemetry::Trace::SpanContext, nil] Parent span context
    # @param otel_tracer [OpenTelemetry::SDK::Trace::Tracer] The OTel tracer
    # @return [OpenTelemetry::SDK::Trace::Span] The created span
    def create_otel_span(name:, otel_tracer:, start_time: nil, parent_span_context: nil)
      if parent_span_context
        # Create child span with parent context
        # Create a non-recording span from the parent context to set in context
        parent_span = OpenTelemetry::Trace.non_recording_span(parent_span_context)
        parent_context = OpenTelemetry::Trace.context_with_span(parent_span)
        OpenTelemetry::Context.with_current(parent_context) do
          otel_tracer.start_span(name, start_timestamp: start_time)
        end
      else
        # Create root span
        otel_tracer.start_span(name, start_timestamp: start_time)
      end
    end

    # Wraps an OpenTelemetry span in the appropriate observation class
    #
    # @param otel_span [OpenTelemetry::SDK::Trace::Span] The OTel span
    # @param type_str [String] Observation type string
    # @param otel_tracer [OpenTelemetry::SDK::Trace::Tracer] The OTel tracer
    # @param attributes [Hash, nil] Optional attributes
    # @return [BaseObservation] Appropriate observation wrapper instance
    def wrap_otel_span(otel_span, type_str, otel_tracer, attributes: nil)
      observation_class = OBSERVATION_TYPE_REGISTRY[type_str] || Span
      observation_class.new(otel_span, otel_tracer, attributes: attributes)
    end
  end
  # rubocop:enable Metrics/ClassLength
end
# rubocop:enable Metrics/ModuleLength
