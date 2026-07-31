# frozen_string_literal: true

module Langfuse
  # Deprecated compatibility wrapper for the former OpenTelemetry setup module.
  #
  # New code should use the client-owned tracer provider directly:
  # `Langfuse.tracer_provider` for the global client, or
  # `Langfuse::Client.new(config).tracer_provider` for explicit clients.
  module OtelSetup
    DEPRECATION_WARNING =
      "Langfuse::OtelSetup is deprecated and will be removed in the next major release. " \
      "Use Langfuse.tracer_provider, Langfuse.force_flush, Langfuse.shutdown, or an explicit " \
      "Langfuse::Client instead."
    private_constant :DEPRECATION_WARNING

    class << self
      # Initialize and return the global Langfuse tracer provider.
      #
      # @param config [Langfuse::Config] ignored; the global configuration is always used
      # @return [OpenTelemetry::SDK::Trace::TracerProvider]
      # @raise [ConfigurationError] if global tracing configuration is incomplete
      def setup(config = Langfuse.configuration)
        warn_deprecated_once
        warn_ignored_config(config)
        Langfuse.tracer_provider
      end

      # Return the already-initialized global Langfuse tracer provider.
      #
      # @return [OpenTelemetry::SDK::Trace::TracerProvider, nil]
      def tracer_provider
        warn_deprecated_once
        current_tracer_provider
      end

      # Shutdown the global Langfuse client.
      #
      # @param timeout [Integer] timeout in seconds
      # @return [void]
      def shutdown(timeout: 30)
        warn_deprecated_once
        Langfuse.shutdown(timeout: timeout)
      end

      # Force flush the global Langfuse client.
      #
      # @param timeout [Integer] timeout in seconds
      # @return [void]
      def force_flush(timeout: 30)
        warn_deprecated_once
        Langfuse.force_flush(timeout: timeout)
      end

      # Check whether the global Langfuse tracer provider is initialized.
      #
      # @return [Boolean]
      def initialized?
        warn_deprecated_once
        !current_tracer_provider.nil?
      end

      # @return [void]
      # @api private
      def reset_deprecation_warning!
        warning_mutex.synchronize do
          @deprecation_warning_emitted = false
        end
      end

      private

      # Passing a non-global config used to work; now it is silently lossy,
      # so call that out instead of letting traces land in the wrong project.
      def warn_ignored_config(config)
        return if config.equal?(Langfuse.configuration)

        Langfuse.configuration.logger.warn(
          "Langfuse::OtelSetup.setup ignores its config argument and always uses the global " \
          "Langfuse configuration. Use Langfuse::Client.new(config).tracer_provider instead."
        )
      end

      def current_tracer_provider
        Langfuse.initialized_client&.initialized_tracer_provider
      end

      def warn_deprecated_once
        return if @deprecation_warning_emitted

        warning_mutex.synchronize do
          return if @deprecation_warning_emitted

          Langfuse.configuration.logger.warn(DEPRECATION_WARNING)
          @deprecation_warning_emitted = true
        end
      end

      def warning_mutex
        @warning_mutex ||= Mutex.new
      end
    end
  end
end
