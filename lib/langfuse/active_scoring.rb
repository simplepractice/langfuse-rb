# frozen_string_literal: true

module Langfuse
  # Resolves the client that should own module-level active score calls.
  #
  # @api private
  module ActiveScoring
    RAW_ACTIVE_SCORING_DEPRECATION =
      "Langfuse.score_active_trace and Langfuse.score_active_observation outside a Langfuse-owned " \
      "observation currently score through the singleton client. This raw OpenTelemetry fallback is " \
      "deprecated and will be removed in the next major release; use Langfuse.client.score_active_* " \
      "or an explicit client instead."
    private_constant :RAW_ACTIVE_SCORING_DEPRECATION

    class << self
      # @return [Client, NoopObservationClient]
      def client
        active_client = ClientContext.current_client
        return active_client if active_client

        warn_raw_active_scoring_once
        Langfuse.client
      end

      # @return [void]
      def reset!
        raw_active_scoring_warning_mutex.synchronize do
          @raw_active_scoring_warning_emitted = false
        end
      end

      private

      def warn_raw_active_scoring_once
        return if @raw_active_scoring_warning_emitted

        raw_active_scoring_warning_mutex.synchronize do
          return if @raw_active_scoring_warning_emitted

          Langfuse.configuration.logger.warn(RAW_ACTIVE_SCORING_DEPRECATION)
          @raw_active_scoring_warning_emitted = true
        end
      end

      def raw_active_scoring_warning_mutex
        @raw_active_scoring_warning_mutex ||= Mutex.new
      end
    end
  end
end
