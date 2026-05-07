# frozen_string_literal: true

module Langfuse
  # Shared public observation API used by the singleton facade and client instances.
  #
  # @api private
  module ObservationMethods
    # Creates a new observation (root or child)
    #
    # This is the module-level factory method that creates observations of any type.
    # It can create root observations (when parent_span_context is nil) or child
    # observations (when parent_span_context is provided).
    #
    # @param name [String] Descriptive name for the observation
    # @param attrs [Hash, Types::SpanAttributes, Types::GenerationAttributes, nil] Observation attributes
    # @param as_type [Symbol, String] Observation type (:span, :generation, :event, etc.)
    # @param trace_id [String, nil] Optional 32-char lowercase hex trace ID to attach the observation to.
    #   Mutually exclusive with `parent_span_context`. Use {Langfuse.create_trace_id} to generate one.
    # @param parent_span_context [OpenTelemetry::Trace::SpanContext, nil] Parent span context for child observations
    # @param start_time [Time, Integer, nil] Optional start time (Time object or Unix timestamp in nanoseconds)
    # @param skip_validation [Boolean] Skip validation (for internal use). Defaults to false.
    # @return [BaseObservation] The observation wrapper (Span, Generation, or Event)
    # @raise [ArgumentError] if an invalid observation type is provided, an invalid `trace_id` is given,
    #   or both `trace_id` and `parent_span_context` are provided
    #
    # @example Create root span
    #   span = Langfuse.start_observation("root-operation", { input: {...} })
    #
    # @example Create child generation
    #   child = Langfuse.start_observation("llm-call", { model: "gpt-4" },
    #                                       as_type: :generation,
    #                                       parent_span_context: parent.otel_span.context)
    #
    # @example Attach to a deterministic trace ID
    #   trace_id = Langfuse.create_trace_id(seed: "order-123")
    #   root = Langfuse.start_observation("process-order", trace_id: trace_id)
    # rubocop:disable Metrics/ParameterLists
    def start_observation(name, attrs = {}, as_type: :span, trace_id: nil, parent_span_context: nil,
                          start_time: nil, skip_validation: false)
      parent_span_context = resolve_trace_context(trace_id, parent_span_context)
      type_str = as_type.to_s
      validate_observation_type!(as_type, type_str) unless skip_validation

      otel_tracer = observation_tracer
      otel_span = create_otel_span(
        name: name,
        start_time: start_time,
        parent_span_context: parent_span_context,
        otel_tracer: otel_tracer
      )
      apply_observation_attributes(otel_span, type_str, attrs)

      observation = wrap_otel_span(otel_span, type_str, otel_tracer)
      # Events auto-end immediately when created
      observation.end if type_str == OBSERVATION_TYPES[:event]
      observation
    end
    # rubocop:enable Metrics/ParameterLists

    # User-facing convenience method for creating root observations
    #
    # @param name [String] Descriptive name for the observation
    # @param attrs [Hash] Observation attributes (optional positional or keyword)
    # @param as_type [Symbol, String] Observation type (:span, :generation, :event, etc.)
    # @param trace_id [String, nil] Optional 32-char lowercase hex trace ID to attach the observation to.
    #   Use {Langfuse.create_trace_id} to generate one. Forwarded to {.start_observation}.
    # @param kwargs [Hash] Additional keyword arguments merged into observation attributes (e.g., input:, output:, metadata:)
    # @yield [observation] Optional block that receives the observation object
    # @yieldparam observation [BaseObservation] The observation object
    # @return [BaseObservation, Object] The observation (or block return value if block given)
    # @raise [ArgumentError] if an invalid `trace_id` is provided
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
    def observe(name, attrs = {}, as_type: :span, trace_id: nil, **kwargs, &block)
      merged_attrs = attrs.to_h.merge(kwargs)
      observation = start_observation(name, merged_attrs, as_type: as_type, trace_id: trace_id)
      return observation unless block

      observation.send(:run_in_context, &block)
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

    # @api private
    def resolve_trace_context(trace_id, parent_span_context)
      return parent_span_context unless trace_id
      raise ArgumentError, "Cannot specify both trace_id and parent_span_context" if parent_span_context

      TraceId.send(:to_span_context, trace_id)
    end

    # @api private
    def validate_observation_type!(as_type, type_str)
      return if valid_observation_type?(as_type)

      valid_types = OBSERVATION_TYPES.values.sort.join(", ")
      raise ArgumentError, "Invalid observation type: #{type_str}. Valid types: #{valid_types}"
    end

    # @api private
    def apply_observation_attributes(otel_span, type_str, attrs)
      # Guard against ended spans — should always be recording here, but safe.
      return unless otel_span.recording?

      otel_attrs = OtelAttributes.create_observation_attributes(type_str, attrs.to_h, mask: observation_mask)
      otel_attrs.each { |key, value| otel_span.set_attribute(key, value) }
    end

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
      observation = observation_class.new(otel_span, otel_tracer, attributes: attributes)
      client = observation_client
      observation.client = client if client
      observation
    end
  end
end
