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
      @should_export_span = config.should_export_span || Langfuse.method(:default_export_span?)
      @app_root_tracker = AppRootTracking::Tracker.new

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
      remember_app_root_state(span, parent_context)
    end

    # Drop spans when the export filter rejects them or raises.
    #
    # @param span [OpenTelemetry::SDK::Trace::Span] The span that ended
    # @return [void]
    def on_finish(span)
      ready_spans = @app_root_tracker.finish(span, exportable: should_export_span?(span))
      ready_spans.each { |ready_span| super(copy_with_app_root(ready_span)) }
    end

    private

    # Sync mode relies on explicit `force_flush` calls, so keep the background flush
    # interval long enough that it rarely fires on its own.
    SYNC_SCHEDULE_DELAY_MS = 60_000
    private_constant :SYNC_SCHEDULE_DELAY_MS

    ExportSpan = Struct.new(:span, :attributes, keyword_init: true) do
      def context
        span.context
      end

      def to_span_data
        span.to_span_data.tap do |span_data|
          span_data.attributes = attributes
          span_data.total_recorded_attributes = [
            span_data.total_recorded_attributes,
            attributes.size
          ].max
        end
      end
    end
    private_constant :ExportSpan

    def schedule_delay_for(config)
      config.tracing_async ? config.flush_interval * 1000 : SYNC_SCHEDULE_DELAY_MS
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

    def remember_app_root_state(span, parent_context)
      propagated_trace_id = Propagation._get_langfuse_trace_id_from_baggage(parent_context)
      trace_claimed = propagated_trace_id == span.context.trace_id.unpack1("H*")
      @app_root_tracker.remember(span, trace_claimed: trace_claimed)
    rescue StandardError => e
      @logger.error(
        "Langfuse app-root tracking failed for span '#{span.name}'. The span will not export: " \
        "#{e.class}: #{e.message}"
      )
    end

    def copy_with_app_root(ready_span)
      span = ready_span.span
      attributes = span.attributes || {}
      return span if (attributes[OtelAttributes::IS_APP_ROOT] == true) == ready_span.app_root

      copied_attributes = attributes.dup
      if ready_span.app_root
        copied_attributes[OtelAttributes::IS_APP_ROOT] = true
      else
        copied_attributes.delete(OtelAttributes::IS_APP_ROOT)
      end
      ExportSpan.new(span: span, attributes: copied_attributes.freeze)
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
