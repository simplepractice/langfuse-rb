# frozen_string_literal: true

require "uri"

module Langfuse
  module Resources
    # Trace API resource operations.
    #
    # @api private
    class Traces
      # @param connection [#call] Callable returning a Faraday connection
      # @param handle_response [#call] Response handler callable
      # @param with_error_handling [#call] Faraday error wrapper callable
      # @return [Traces]
      def initialize(connection:, handle_response:, with_error_handling:)
        @connection = connection
        @handle_response = handle_response
        @with_error_handling = with_error_handling
      end

      # List traces in the project.
      #
      # @param options [Hash] Trace list filters
      # @return [Array<Hash>] Trace hashes
      def list(**)
        result = list_paginated(**)
        result["data"] || []
      end

      # List traces with pagination metadata.
      #
      # @param options [Hash] Trace list filters
      # @return [Hash] Full response hash
      def list_paginated(**options)
        with_error_handling do
          response = connection.get("/api/public/traces", build_traces_params(**options))
          handle_response(response)
        end
      end

      # Fetch one trace by ID.
      #
      # @param id [String] Trace ID
      # @return [Hash] Trace data
      def get(id)
        with_error_handling do
          response = connection.get("/api/public/traces/#{URI.encode_uri_component(id)}")
          handle_response(response)
        end
      end

      private

      def build_traces_params(**options)
        {
          page: options[:page], limit: options[:limit], userId: options[:user_id], name: options[:name],
          sessionId: options[:session_id],
          fromTimestamp: options[:from_timestamp]&.iso8601,
          toTimestamp: options[:to_timestamp]&.iso8601,
          orderBy: options[:order_by], tags: options[:tags], version: options[:version],
          release: options[:release], environment: options[:environment], fields: options[:fields],
          filter: options[:filter]
        }.compact
      end

      def connection
        @connection.call
      end

      def handle_response(response)
        @handle_response.call(response)
      end

      def with_error_handling(&)
        @with_error_handling.call(&)
      end
    end
  end
end
