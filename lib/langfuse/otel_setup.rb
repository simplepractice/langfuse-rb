# frozen_string_literal: true

require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "base64"

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
        validate_tracing_config!(config)
        return existing_provider_for(config) if initialized?

        candidate_provider = nil
        provider = nil
        created = false
        candidate_provider = build_tracer_provider(config)
        provider, created = publish_provider(candidate_provider, tracing_config_snapshot(config))
        unless created
          candidate_provider.shutdown(timeout: 30)
          return existing_provider_for(config)
        end

        log_initialized(config)
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

      def publish_provider(provider, snapshot)
        created = false
        current = nil

        # This mutex only guards publication so setup never exposes a half-built provider.
        setup_mutex.synchronize do
          if @tracer_provider
            current = @tracer_provider
          else
            @tracer_provider = provider
            @config_snapshot = snapshot
            current = provider
            created = true
          end
        end

        [current, created]
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

      def validate_tracing_config!(config)
        raise ConfigurationError, "public_key is required" if blank?(config.public_key)
        raise ConfigurationError, "secret_key is required" if blank?(config.secret_key)
        raise ConfigurationError, "base_url cannot be empty" if blank?(config.base_url)
        return if config.should_export_span.nil? || config.should_export_span.respond_to?(:call)

        raise ConfigurationError, "should_export_span must respond to #call"
      end

      def tracing_config_snapshot(config)
        TRACING_CONFIG_FIELDS.to_h { |field| [field, config.public_send(field)] }.freeze
      end

      def setup_mutex
        @setup_mutex ||= Mutex.new
      end

      def blank?(value)
        value.nil? || value.empty?
      end

      def build_headers(public_key, secret_key)
        credentials = "#{public_key}:#{secret_key}"
        encoded = Base64.strict_encode64(credentials)
        { "Authorization" => "Basic #{encoded}" }
      end

      def build_sampler(sample_rate)
        if sample_rate < 1.0
          OpenTelemetry::SDK::Trace::Samplers::TraceIdRatioBased.new(sample_rate)
        else
          OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON
        end
      end
    end
  end
  # rubocop:enable Metrics/ModuleLength
end
