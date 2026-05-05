# frozen_string_literal: true

require_relative "../chat_prompt_client"
require_relative "../text_prompt_client"

module Langfuse
  # Internal factory for constructing prompt clients while preserving the flat
  # public Client API.
  #
  # @api private
  class PromptClientFactory
    # @return [Array<Symbol>] Supported prompt types
    VALID_TYPES = %i[text chat].freeze

    class << self
      # Build a prompt client from API prompt data.
      #
      # @param prompt_data [Hash] Prompt data returned by the API
      # @param is_fallback [Boolean] Whether the client wraps fallback content
      # @return [TextPromptClient, ChatPromptClient]
      # @raise [ApiError] if the prompt type is unknown
      def build(prompt_data, is_fallback: false)
        case prompt_data["type"]
        when "text"
          TextPromptClient.new(prompt_data, is_fallback: is_fallback)
        when "chat"
          ChatPromptClient.new(prompt_data, is_fallback: is_fallback)
        else
          raise ApiError, "Unknown prompt type: #{prompt_data['type']}"
        end
      end

      # Build a fallback prompt client from caller-provided fallback content.
      #
      # @param name [String] Prompt name
      # @param fallback [String, Array<Hash>] Fallback prompt content
      # @param type [Symbol] Prompt type (:text or :chat)
      # @return [TextPromptClient, ChatPromptClient]
      # @raise [ArgumentError] if the fallback type is invalid
      def build_fallback(name, fallback, type)
        validate_type!(type)

        build(
          {
            "name" => name,
            "version" => 0,
            "type" => type.to_s,
            "prompt" => fallback,
            "labels" => [],
            "tags" => ["fallback"],
            "config" => {}
          },
          is_fallback: true
        )
      end

      # Validate a prompt type symbol.
      #
      # @param type [Symbol] Prompt type
      # @return [void]
      # @raise [ArgumentError] if the prompt type is invalid
      def validate_type!(type)
        return if VALID_TYPES.include?(type)

        raise ArgumentError, "Invalid type: #{type}. Must be :text or :chat"
      end

      # Validate prompt content against the declared prompt type.
      #
      # @param prompt [String, Array<Hash>] Prompt content
      # @param type [Symbol] Prompt type
      # @return [void]
      # @raise [ArgumentError] if the content does not match the type
      def validate_content!(prompt, type)
        case type
        when :text
          raise ArgumentError, "Text prompt must be a String" unless prompt.is_a?(String)
        when :chat
          raise ArgumentError, "Chat prompt must be an Array" unless prompt.is_a?(Array)
        end
      end

      # Normalize prompt content for create/update payloads.
      #
      # @param prompt [String, Array<Hash>] Prompt content
      # @param type [Symbol] Prompt type
      # @return [String, Array<Hash>] Normalized prompt content
      def normalize_content(prompt, type)
        return prompt if type == :text

        prompt.map do |message|
          normalized = message.transform_keys(&:to_s)
          next placeholder_prompt_content(normalized) if normalized["type"] == ChatPromptClient::PLACEHOLDER_TYPE

          normalize_chat_message_content(normalized)
        end
      end

      private

      def placeholder_prompt_content(message)
        {
          "type" => ChatPromptClient::PLACEHOLDER_TYPE,
          "name" => message["name"].to_s
        }
      end

      def normalize_chat_message_content(message)
        message.merge(
          "role" => message["role"]&.to_s,
          "content" => message["content"]
        )
      end
    end
  end
end
