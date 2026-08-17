# frozen_string_literal: true

require "opentelemetry/sdk"

module Langfuse
  # Stops trace export while the live telemetry kill switch is disabled.
  #
  # @api private
  class TraceExportGuard
    SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
    private_constant :SUCCESS

    # @param delegate [#export, #force_flush, #shutdown] OpenTelemetry span exporter
    # @param config [Langfuse::Config] Live SDK configuration
    def initialize(delegate:, config:)
      @delegate = delegate
      @config = config
    end

    # Export spans only while trace export is enabled.
    #
    # @param span_data [Enumerable<OpenTelemetry::SDK::Trace::SpanData>]
    # @param timeout [Numeric, nil]
    # @return [Integer] OpenTelemetry export result code
    def export(span_data, timeout: nil)
      return SUCCESS unless @config.trace_export_enabled?

      @delegate.export(span_data, timeout: timeout)
    end

    # @param timeout [Numeric, nil]
    # @return [Object] delegate result or OpenTelemetry success
    def force_flush(timeout: nil)
      return SUCCESS unless @config.trace_export_enabled?

      @delegate.force_flush(timeout: timeout)
    end

    # Release exporter resources after the guarded processor drains its queue.
    #
    # @param timeout [Numeric, nil]
    # @return [Object] delegate shutdown result
    def shutdown(timeout: nil)
      @delegate.shutdown(timeout: timeout)
    end
  end
end
