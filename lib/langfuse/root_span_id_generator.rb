# frozen_string_literal: true

module Langfuse
  # Supplies deterministic IDs only during explicit root creation on one provider.
  #
  # @api private
  class RootSpanIdGenerator
    def initialize
      @trace_id_key = OpenTelemetry::Context.create_key("langfuse-root-trace-id")
    end

    def generate_trace_id
      OpenTelemetry::Context.value(@trace_id_key) || OpenTelemetry::Trace.generate_trace_id
    end

    def generate_span_id
      OpenTelemetry::Trace.generate_span_id
    end

    # A trace ID identifies a trace, not a missing parent. Preserve propagated
    # attributes while clearing the ambient span and its internal root claim.
    # The provider-local key and Context scope isolate concurrent fibers/threads
    # and restore the caller's context even when span creation raises.
    #
    # @param trace_id [String] Validated binary W3C trace ID
    # @yieldparam context [OpenTelemetry::Context] Parentless root context
    # @return [Object] The block result
    # @api private
    def with_trace_id(trace_id)
      context = OpenTelemetry::Trace.context_with_span(OpenTelemetry::Trace::Span::INVALID)
      if Propagation.baggage_available?
        context = OpenTelemetry::Baggage.remove_value(Propagation::LANGFUSE_TRACE_ID_BAGGAGE_KEY, context: context)
      end
      context = context.set_value(@trace_id_key, trace_id)
      OpenTelemetry::Context.with_current(context) { yield context }
    end
  end
end
