# frozen_string_literal: true

require "opentelemetry/context"

module Langfuse
  # Tracks the Langfuse client that owns the currently active observation.
  #
  # @api private
  module ClientContext
    KEY = OpenTelemetry::Context.create_key("langfuse.client")
    private_constant :KEY

    class << self
      # @return [Client, NoopObservationClient, nil]
      def current_client
        OpenTelemetry::Context.current.value(KEY)
      end

      # @param client [Client, NoopObservationClient]
      # @param context [OpenTelemetry::Context]
      # @return [OpenTelemetry::Context]
      def context_with_client(client, context: OpenTelemetry::Context.current)
        context.set_value(KEY, client)
      end
    end
  end
end
