# frozen_string_literal: true

require "opentelemetry/sdk"

module Langfuse
  # Span processor that applies default and propagated trace attributes on new spans.
  #
  # On span start, this processor first applies configured trace defaults
  # (environment/release), then overlays attributes propagated in OpenTelemetry
  # context (user/session/metadata/tags/version). This ensures consistent
  # trace dimensions while still honoring per-request propagation.
  #
  # @api private
  class SpanProcessor < OpenTelemetry::SDK::Trace::SpanProcessor
    # @param config [Langfuse::Config, nil] SDK configuration used to build trace defaults
    def initialize(config: Langfuse.configuration)
      @default_trace_attributes = build_default_trace_attributes(config).freeze
      super()
    end

    # Called when a span starts
    #
    # @param span [OpenTelemetry::SDK::Trace::Span] The span that started
    # @param parent_context [OpenTelemetry::Context] The parent context
    # @return [void]
    def on_start(span, parent_context)
      return unless span.recording?

      apply_attributes(span, @default_trace_attributes)
      apply_attributes(span, propagated_attributes(parent_context))
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

    private

    def build_default_trace_attributes(config)
      return {} unless config

      OtelAttributes.create_trace_attributes(
        environment: config.environment,
        release: config.release
      )
    end

    def propagated_attributes(parent_context)
      return {} unless parent_context

      Propagation.get_propagated_attributes_from_context(parent_context)
    end

    def apply_attributes(span, attributes)
      attributes.each { |key, value| span.set_attribute(key, value) }
    end
  end
end
