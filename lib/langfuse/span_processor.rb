# frozen_string_literal: true

require "opentelemetry/sdk"

module Langfuse
  # Span processor that automatically sets propagated attributes on new spans.
  #
  # This processor reads propagated attributes from OpenTelemetry context and
  # sets them on spans when they are created. This ensures that attributes set
  # via `propagate_attributes` are automatically applied to all child spans.
  #
  # @api private
  class SpanProcessor < OpenTelemetry::SDK::Trace::SpanProcessor
    # Called when a span starts
    #
    # @param span [OpenTelemetry::SDK::Trace::Span] The span that started
    # @param parent_context [OpenTelemetry::Context] The parent context
    # @return [void]
    def on_start(span, parent_context)
      return unless span.recording?

      # Get propagated attributes from context
      propagated_attrs = Propagation.get_propagated_attributes_from_context(parent_context)

      # Set attributes on span
      propagated_attrs.each do |key, value|
        span.set_attribute(key, value)
      end
    end

    # Called when a span ends
    #
    # @param span [OpenTelemetry::SDK::Trace::Span] The span that ended
    # @return [void]
    def on_finish(span)
      # No-op - we don't need to do anything when spans finish
    end

    # Shutdown the processor
    #
    # @param timeout [Integer, nil] Timeout in seconds (unused for this processor)
    # @return [Integer] Always returns 0 (no timeout needed for no-op)
    def shutdown(timeout: nil)
      # No-op - nothing to clean up
      # Return 0 to match OpenTelemetry SDK expectation (it finds max timeout from processors)
      _ = timeout # Suppress unused argument warning
      0
    end

    # Force flush (no-op for this processor)
    #
    # @param timeout [Integer, nil] Timeout in seconds (unused for this processor)
    # @return [Integer] Always returns 0 (no timeout needed for no-op)
    def force_flush(timeout: nil)
      # No-op - nothing to flush
      # Return 0 to match OpenTelemetry SDK expectation (it finds max timeout from processors)
      _ = timeout # Suppress unused argument warning
      0
    end
  end
end
