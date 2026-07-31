# frozen_string_literal: true

module Langfuse
  # Shared observation factory methods for the singleton facade and explicit clients.
  #
  # @api private
  module ObservationMethods
    # Registry mapping observation type strings to their wrapper classes.
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

    # @param name [String] Descriptive name for the observation
    # @param attrs [Hash, Types::SpanAttributes, Types::GenerationAttributes, nil] Observation attributes
    # @param as_type [Symbol, String] Observation type (:span, :generation, :event, etc.)
    # @param trace_id [String, nil] Optional 32-char lowercase hex trace ID.
    # @param parent_span_context [OpenTelemetry::Trace::SpanContext, nil] Parent span context
    # @param start_time [Time, Integer, nil] Optional start time
    # @param skip_validation [Boolean] Skip validation for internal child factories
    # @return [BaseObservation] The observation wrapper
    # @raise [ArgumentError] if observation type or trace context arguments are invalid
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
      finish_event_if_needed(wrap_otel_span(otel_span, type_str, otel_tracer), type_str)
    end
    # rubocop:enable Metrics/ParameterLists

    # @param name [String] Descriptive name for the observation
    # @param attrs [Hash] Observation attributes
    # @param as_type [Symbol, String] Observation type
    # @param trace_id [String, nil] Optional 32-char lowercase hex trace ID.
    # @param kwargs [Hash] Additional observation attributes
    # @yield [observation] Optional block that receives the observation
    # @return [BaseObservation, Object] The observation or block return value
    # @raise [ArgumentError] if an invalid `trace_id` is provided
    def observe(name, attrs = {}, as_type: :span, trace_id: nil, **kwargs, &block)
      merged_attrs = attrs.to_h.merge(kwargs)
      observation = start_observation(name, merged_attrs, as_type: as_type, trace_id: trace_id)
      return observation unless block

      observation.send(:run_in_context, &block)
    end

    private

    def resolve_trace_context(trace_id, parent_span_context)
      return parent_span_context unless trace_id
      raise ArgumentError, "Cannot specify both trace_id and parent_span_context" if parent_span_context

      TraceId.send(:to_span_context, trace_id)
    end

    def validate_observation_type!(as_type, type_str)
      return if valid_observation_type?(as_type)

      valid_types = OBSERVATION_TYPES.values.sort.join(", ")
      raise ArgumentError, "Invalid observation type: #{type_str}. Valid types: #{valid_types}"
    end

    def apply_observation_attributes(otel_span, type_str, attrs)
      return unless otel_span.recording?

      otel_attrs = OtelAttributes.create_observation_attributes(type_str, attrs.to_h, mask: observation_mask)
      otel_attrs.each { |key, value| otel_span.set_attribute(key, value) }
    end

    def valid_observation_type?(type)
      return false unless type.respond_to?(:to_sym)

      OBSERVATION_TYPES.key?(type.to_sym)
    rescue TypeError
      false
    end

    def create_otel_span(name:, otel_tracer:, start_time: nil, parent_span_context: nil)
      return otel_tracer.start_span(name, start_timestamp: start_time) unless parent_span_context

      parent_span = OpenTelemetry::Trace.non_recording_span(parent_span_context)
      parent_context = OpenTelemetry::Trace.context_with_span(parent_span)
      OpenTelemetry::Context.with_current(parent_context) do
        otel_tracer.start_span(name, start_timestamp: start_time)
      end
    end

    def wrap_otel_span(otel_span, type_str, otel_tracer)
      observation_class = OBSERVATION_TYPE_REGISTRY[type_str] || Span
      observation_class.new(otel_span, otel_tracer, client: observation_owner)
    end

    def finish_event_if_needed(observation, type_str)
      observation.end if type_str == OBSERVATION_TYPES[:event]
      observation
    end
  end
end
