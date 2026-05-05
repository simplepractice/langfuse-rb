# frozen_string_literal: true

require "uri"

module Langfuse
  module Resources
    # Prompt API resource operations.
    #
    # @api private
    class Prompts
      # @param connection [#call] Callable returning a Faraday connection
      # @param handle_response [#call] Response handler callable
      # @param with_error_handling [#call] Faraday error wrapper callable
      # @param invalidate_cache [#call] Prompt cache invalidation callable
      # @return [Prompts]
      def initialize(connection:, handle_response:, with_error_handling:, invalidate_cache:)
        @connection = connection
        @handle_response = handle_response
        @with_error_handling = with_error_handling
        @invalidate_cache = invalidate_cache
      end

      # List all prompts in the Langfuse project.
      #
      # @param page [Integer, nil] Optional page number
      # @param limit [Integer, nil] Optional page size
      # @return [Array<Hash>] Prompt metadata hashes
      def list(page: nil, limit: nil)
        with_error_handling do
          result = handle_response(connection.get("/api/public/v2/prompts", { page: page, limit: limit }.compact))
          result["data"] || []
        end
      end

      # Fetch one prompt from the API.
      #
      # @param name [String] Prompt name
      # @param version [Integer, nil] Optional version number
      # @param label [String, nil] Optional label
      # @return [Hash] Prompt data
      def fetch(name, version: nil, label: nil)
        with_error_handling do
          path = "/api/public/v2/prompts/#{URI.encode_uri_component(name)}"
          handle_response(connection.get(path, { version: version, label: label }.compact))
        end
      end

      # Create a prompt.
      #
      # @param name [String] Prompt name
      # @param prompt [String, Array<Hash>] Prompt content
      # @param type [String] Prompt type
      # @param config [Hash] Prompt config
      # @param labels [Array<String>] Prompt labels
      # @param tags [Array<String>] Prompt tags
      # @param commit_message [String, nil] Optional commit message
      # @return [Hash] Created prompt data
      # rubocop:disable Metrics/ParameterLists
      def create(name:, prompt:, type:, config: {}, labels: [], tags: [], commit_message: nil)
        with_error_handling do
          payload = {
            name: name,
            prompt: prompt,
            type: type,
            config: config,
            labels: labels,
            tags: tags
          }
          payload[:commitMessage] = commit_message if commit_message

          handle_response(connection.post("/api/public/v2/prompts", payload)).tap { @invalidate_cache.call(name) }
        end
      end
      # rubocop:enable Metrics/ParameterLists

      # Update prompt labels for one version.
      #
      # @param name [String] Prompt name
      # @param version [Integer] Prompt version
      # @param labels [Array<String>] Replacement labels
      # @return [Hash] Updated prompt data
      # @raise [ArgumentError] if labels is not an array
      def update(name:, version:, labels:)
        raise ArgumentError, "labels must be an array" unless labels.is_a?(Array)

        with_error_handling do
          path = "/api/public/v2/prompts/#{URI.encode_uri_component(name)}/versions/#{version}"
          handle_response(connection.patch(path, { newLabels: labels })).tap { @invalidate_cache.call(name) }
        end
      end

      private

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
