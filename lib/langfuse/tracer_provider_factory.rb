# frozen_string_literal: true

require "base64"
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"

module Langfuse
  # Builds isolated OpenTelemetry tracer providers for Langfuse clients.
  #
  # @api private
  module TracerProviderFactory
    class << self
      # @param config [Langfuse::Config] SDK configuration used for tracing
      # @param exporter [#export, #force_flush, #shutdown, nil] optional test/export override
      # @return [OpenTelemetry::SDK::Trace::TracerProvider]
      # @raise [ConfigurationError] if tracing configuration is incomplete
      def build(config, exporter: nil)
        validate_tracing_config!(config)

        provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
          sampler: build_sampler(config.sample_rate)
        )
        provider.add_span_processor(
          SpanProcessor.new(config: config, exporter: exporter || build_exporter(config))
        )
        provider
      end

      # @param config [Langfuse::Config] SDK configuration used for exporter auth
      # @return [OpenTelemetry::Exporter::OTLP::Exporter]
      def build_exporter(config)
        OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: "#{config.base_url}/api/public/otel/v1/traces",
          headers: build_headers(config.public_key, config.secret_key),
          compression: "gzip"
        )
      end

      # @param config [Langfuse::Config] SDK configuration used for tracing
      # @return [void]
      # @raise [ConfigurationError] if tracing configuration is incomplete
      def validate_tracing_config!(config)
        raise ConfigurationError, "public_key is required" if blank?(config.public_key)
        raise ConfigurationError, "secret_key is required" if blank?(config.secret_key)
        raise ConfigurationError, "base_url cannot be empty" if blank?(config.base_url)
        return if config.should_export_span.nil? || config.should_export_span.respond_to?(:call)

        raise ConfigurationError, "should_export_span must respond to #call"
      end

      private

      def blank?(value)
        value.nil? || value.empty?
      end

      def build_headers(public_key, secret_key)
        credentials = "#{public_key}:#{secret_key}"
        encoded = Base64.strict_encode64(credentials)
        { "Authorization" => "Basic #{encoded}" }
      end

      def build_sampler(sample_rate)
        Sampling.build_sampler(sample_rate) || OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON
      end
    end
  end
end
