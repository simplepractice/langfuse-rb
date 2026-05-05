# frozen_string_literal: true

require "faraday"

module Langfuse
  module Resources
    # Batch ingestion resource operations.
    #
    # @api private
    class Batches
      # @param connection [#call] Callable returning a Faraday connection
      # @param handle_batch_response [#call] Batch response handler callable
      # @param logger [Logger] Logger for transport errors
      # @return [Batches]
      def initialize(connection:, handle_batch_response:, logger:)
        @connection = connection
        @handle_batch_response = handle_batch_response
        @logger = logger
      end

      # Send a batch of ingestion events.
      #
      # @param events [Array<Hash>] Events to send
      # @return [void]
      # @raise [ArgumentError] if events is not a non-empty array
      # @raise [ApiError] if the batch request fails
      def send_batch(events)
        raise ArgumentError, "events must be an array" unless events.is_a?(Array)
        raise ArgumentError, "events array cannot be empty" if events.empty?

        response = connection.post("/api/public/ingestion", { batch: events })
        handle_batch_response(response)
      rescue Faraday::RetriableResponse => e
        logger.error("Langfuse batch send failed: Retries exhausted - #{e.response.status}")
        handle_batch_response(e.response)
      rescue Faraday::Error => e
        logger.error("Langfuse batch send failed: #{e.message}")
        raise ApiError, "Batch send failed: #{e.message}"
      end

      private

      attr_reader :logger

      def connection
        @connection.call
      end

      def handle_batch_response(response)
        @handle_batch_response.call(response)
      end
    end
  end
end
