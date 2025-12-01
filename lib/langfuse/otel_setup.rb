# frozen_string_literal: true

require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/trace/propagation/trace_context"
require "base64"

module Langfuse
  # OpenTelemetry initialization and setup
  #
  # Handles configuration of the OTel SDK with Langfuse OTLP exporter
  # when tracing is enabled.
  #
  module OtelSetup
    class << self
      attr_reader :tracer_provider

      # Initialize OpenTelemetry with Langfuse OTLP exporter
      #
      # @param config [Langfuse::Config] The Langfuse configuration
      # @return [void]
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def setup(config)
        # Create OTLP exporter configured for Langfuse
        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: "#{config.base_url}/api/public/otel/v1/traces",
          headers: build_headers(config.public_key, config.secret_key),
          compression: "gzip"
        )

        # Create processor based on async configuration
        # IMPORTANT: Always use BatchSpanProcessor (even in sync mode) to ensure spans
        # are exported together, which allows proper parent-child relationship detection
        processor = if config.tracing_async
                      # Async: BatchSpanProcessor batches and sends in background
                      OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
                        exporter,
                        max_queue_size: config.batch_size * 2, # Buffer more than batch_size
                        schedule_delay: config.flush_interval * 1000, # Convert seconds to milliseconds
                        max_export_batch_size: config.batch_size
                      )
                    else
                      # Sync: BatchSpanProcessor with minimal delay (flushes on force_flush)
                      # This collects spans from the same trace and exports them together,
                      # which is critical for correct parent_observation_id calculation
                      OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
                        exporter,
                        max_queue_size: config.batch_size * 2,
                        schedule_delay: 60_000, # 60 seconds (relies on explicit force_flush)
                        max_export_batch_size: config.batch_size
                      )
                    end

        # Create TracerProvider with processor
        @tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
        @tracer_provider.add_span_processor(processor)

        # Add span processor for propagated attributes
        # This must be added AFTER the BatchSpanProcessor to ensure attributes are set before export
        span_processor = SpanProcessor.new
        @tracer_provider.add_span_processor(span_processor)

        # Set as global tracer provider
        OpenTelemetry.tracer_provider = @tracer_provider

        # Configure W3C TraceContext propagator if not already set
        if OpenTelemetry.propagation.is_a?(OpenTelemetry::Context::Propagation::NoopTextMapPropagator)
          OpenTelemetry.propagation = OpenTelemetry::Trace::Propagation::TraceContext::TextMapPropagator.new
          config.logger.debug("Langfuse: Configured W3C TraceContext propagator")
        else
          config.logger.debug("Langfuse: Using existing propagator: #{OpenTelemetry.propagation.class}")
        end

        mode = config.tracing_async ? "async" : "sync"
        config.logger.info("Langfuse tracing initialized with OpenTelemetry (#{mode} mode)")
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # Shutdown the tracer provider and flush any pending spans
      #
      # @param timeout [Integer] Timeout in seconds
      # @return [void]
      def shutdown(timeout: 30)
        return unless @tracer_provider

        @tracer_provider.shutdown(timeout: timeout)
        @tracer_provider = nil
      end

      # Force flush all pending spans
      #
      # @param timeout [Integer] Timeout in seconds
      # @return [void]
      def force_flush(timeout: 30)
        return unless @tracer_provider

        @tracer_provider.force_flush(timeout: timeout)
      end

      # Check if OTel is initialized
      #
      # @return [Boolean]
      def initialized?
        !@tracer_provider.nil?
      end

      private

      # Build HTTP headers for Langfuse OTLP endpoint
      #
      # @param public_key [String] Langfuse public API key
      # @param secret_key [String] Langfuse secret API key
      # @return [Hash] HTTP headers with Basic Auth
      def build_headers(public_key, secret_key)
        credentials = "#{public_key}:#{secret_key}"
        encoded = Base64.strict_encode64(credentials)
        {
          "Authorization" => "Basic #{encoded}"
        }
      end
    end
  end
end
