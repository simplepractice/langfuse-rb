# frozen_string_literal: true

require "opentelemetry/sdk"

module Langfuse
  # Batch span processor that owns Langfuse's enrichment and export filtering.
  #
  # @api private
  class SpanProcessor < OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor
    # @param config [Langfuse::Config] SDK configuration used for defaults and filtering
    # @param exporter [#export, #force_flush, #shutdown] Span exporter used by the batch processor
    def initialize(config:, exporter:)
      @logger = config.logger
      @default_trace_attributes = build_default_trace_attributes(config).freeze
      @should_export_span = config.should_export_span || Langfuse.method(:is_default_export_span)

      super(
        exporter,
        max_queue_size: config.batch_size * 2,
        schedule_delay: schedule_delay_for(config),
        max_export_batch_size: config.batch_size
      )
    end

    # Apply Langfuse trace defaults and propagated attributes before a span records work.
    #
    # @param span [OpenTelemetry::SDK::Trace::Span] The span that started
    # @param parent_context [OpenTelemetry::Context] The parent context
    # @return [void]
    def on_start(span, parent_context)
      return unless span.recording?

      apply_attributes(span, @default_trace_attributes)
      apply_attributes(span, propagated_attributes(parent_context))
    end

    # Drop spans when the export filter rejects them or raises.
    #
    # @param span [OpenTelemetry::SDK::Trace::Span] The span that ended
    # @return [void]
    def on_finish(span)
      return unless should_export_span?(span)

      super
    end

    private

    def schedule_delay_for(config)
      config.tracing_async ? config.flush_interval * 1000 : 60_000
    end

    def build_default_trace_attributes(config)
      OtelAttributes.create_trace_attributes(
        { environment: config.environment, release: config.release }
      )
    end

    def propagated_attributes(parent_context)
      return {} unless parent_context

      Propagation.get_propagated_attributes_from_context(parent_context)
    end

    def apply_attributes(span, attributes)
      attributes.each { |key, value| span.set_attribute(key, value) }
    end

    def should_export_span?(span)
      @should_export_span.call(span)
    rescue StandardError => e
      @logger.error(
        "Langfuse tracing dropped span '#{span.name}' because should_export_span raised: " \
        "#{e.class}: #{e.message}"
      )
      false
    end
  end
end
