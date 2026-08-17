# frozen_string_literal: true

require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "base64"
require_relative "masking_exporter"

module Langfuse
  # OpenTelemetry initialization and setup for Langfuse tracing.
  # rubocop:disable Metrics/ModuleLength
  module OtelSetup
    TRACING_CONFIG_FIELDS = %i[
      public_key
      secret_key
      base_url
      environment
      release
      sample_rate
      should_export_span
      mask_otel_spans
      metrics_reporter
      span_exporter
      tracing_async
      batch_size
      flush_interval
    ].freeze
    private_constant(:TRACING_CONFIG_FIELDS)

    class << self
      # @return [OpenTelemetry::SDK::Trace::TracerProvider, nil] The configured internal tracer provider
      attr_reader :tracer_provider

      # Initialize Langfuse's internal tracer provider without mutating global OpenTelemetry state.
      #
      # @param config [Langfuse::Config] The Langfuse configuration
      # @return [OpenTelemetry::SDK::Trace::TracerProvider]
      def setup(config)
        config.validate_tracing!
        provider, created = setup_mutex.synchronize { setup_locked(config) }

        log_initialized(config) if created
        provider
      rescue StandardError
        rollback_provider(provider) if created
        raise
      end

      # Shutdown the internal tracer provider and flush any pending spans.
      #
      # @param timeout [Integer] Timeout in seconds
      # @return [void]
      def shutdown(timeout: 30)
        provider = nil
        setup_mutex.synchronize do
          provider = @tracer_provider
          @tracer_provider = nil
          @config_snapshot = nil
        end
        provider&.shutdown(timeout: timeout)
      end

      # Force flush all pending spans on the internal tracer provider.
      #
      # @param timeout [Integer] Timeout in seconds
      # @return [void]
      def force_flush(timeout: 30)
        @tracer_provider&.force_flush(timeout: timeout)
      end

      # Check if Langfuse tracing has been initialized.
      #
      # @return [Boolean]
      def initialized?
        !@tracer_provider.nil?
      end

      private

      def existing_provider_for(config)
        snapshot = tracing_config_snapshot(config)
        if @config_snapshot == snapshot
          config.logger.debug("Langfuse tracing already initialized; reusing existing tracer provider")
        else
          config.logger.warn(
            "Langfuse tracing is already initialized. Changes to #{TRACING_CONFIG_FIELDS.join(', ')} " \
            "require Langfuse.reset! before they take effect."
          )
        end
        @tracer_provider
      end

      def setup_locked(config)
        return [existing_provider_for(config), false] if @tracer_provider

        provider = build_tracer_provider(config)
        @tracer_provider = provider
        @config_snapshot = tracing_config_snapshot(config)
        [provider, true]
      end

      def rollback_provider(provider)
        setup_mutex.synchronize do
          return unless @tracer_provider.equal?(provider)

          @tracer_provider = nil
          @config_snapshot = nil
        end
        provider.shutdown(timeout: 1)
      rescue StandardError
        nil
      end

      def build_tracer_provider(config)
        provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
          sampler: build_sampler(config.sample_rate)
        )
        provider.add_span_processor(
          SpanProcessor.new(config: config, exporter: build_exporter(config))
        )
        provider
      end

      def build_exporter(config)
        exporter = config.span_exporter || build_otlp_exporter(config)
        return exporter unless config.mask_otel_spans

        MaskingExporter.new(delegate: exporter, hook: config.mask_otel_spans, logger: config.logger)
      end

      def build_otlp_exporter(config)
        OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: "#{config.base_url}/api/public/otel/v1/traces",
          headers: build_headers(config.public_key, config.secret_key),
          compression: "gzip"
        )
      end

      def log_initialized(config)
        mode = config.tracing_async ? "async" : "sync"
        config.logger.info("Langfuse tracing initialized with OpenTelemetry (#{mode} mode)")
      end

      def tracing_config_snapshot(config)
        TRACING_CONFIG_FIELDS.to_h { |field| [field, config.public_send(field)] }.freeze
      end

      def setup_mutex
        @setup_mutex ||= Mutex.new
      end

      def build_headers(public_key, secret_key)
        credentials = "#{public_key}:#{secret_key}"
        encoded = Base64.strict_encode64(credentials)
        {
          "Authorization" => "Basic #{encoded}",
          "x-langfuse-ingestion-version" => "4",
          "x-langfuse-sdk-name" => "ruby",
          "x-langfuse-sdk-version" => Langfuse::VERSION,
          "x-langfuse-public-key" => public_key
        }
      end

      def build_sampler(sample_rate)
        Sampling.build_sampler(sample_rate) || OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON
      end
    end
  end
  # rubocop:enable Metrics/ModuleLength
end
