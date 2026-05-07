# frozen_string_literal: true

require_relative "tracer_provider_factory"

module Langfuse
  # OpenTelemetry initialization and setup for Langfuse tracing.
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
        return existing_provider_for(config) if initialized?

        candidate_provider = nil
        provider = nil
        created = false
        candidate_provider = TracerProviderFactory.build(config)
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
    end
  end
end
