# frozen_string_literal: true

require_relative "prompts/prompt_renderer"
require_relative "prompts/prompt_client_metadata"

module Langfuse
  # Chat prompt client for compiling chat prompts with variable substitution
  #
  # Handles chat-based prompts from Langfuse, providing Mustache templating
  # for variable substitution in role-based messages.
  #
  # @example Basic usage
  #   prompt_data = api_client.get_prompt("support_chat")
  #   chat_prompt = Langfuse::ChatPromptClient.new(prompt_data)
  #   chat_prompt.compile(variables: { user_name: "Alice", issue: "login" })
  #   # => [{ role: "system", content: "You are a support agent..." }, ...]
  #
  # @example Accessing metadata
  #   chat_prompt.name      # => "support_chat"
  #   chat_prompt.version   # => 1
  #   chat_prompt.labels    # => ["production"]
  #
  class ChatPromptClient
    PLACEHOLDER_TYPE = "placeholder"

    include PromptClientMetadata

    # Initialize a new chat prompt client
    #
    # @param prompt_data [Hash] The prompt data from the API
    # @param is_fallback [Boolean] Whether this client wraps caller-provided fallback content
    # @raise [ArgumentError] if prompt data is invalid
    def initialize(prompt_data, is_fallback: false)
      validate_prompt_data!(prompt_data)
      initialize_prompt_metadata(prompt_data, is_fallback: is_fallback)
    end

    # @return [String] Prompt type ("chat")
    def type
      "chat"
    end

    # Compile the chat prompt with variable substitution and message placeholders
    #
    # Returns an array of message hashes with roles and compiled content.
    # Placeholder entries are resolved from keyword arguments: arrays are
    # expanded, empty arrays are skipped, unresolved placeholders stay in the
    # output, and malformed values raise before invalid messages are sent to
    # an LLM provider.
    #
    # @param kwargs [Hash] Variables and placeholder values to compile
    # @return [Array<Hash>] Array of compiled messages and unresolved placeholders
    # @raise [ArgumentError] if a placeholder value is malformed
    #
    # @example
    #   chat_prompt.compile(name: "Alice", topic: "Ruby")
    #   # => [
    #   #   { role: :system, content: "You are a helpful assistant." },
    #   #   { role: :user, content: "Hello Alice, let's discuss Ruby!" }
    #   # ]
    def compile(**kwargs)
      unresolved = []
      compiled = []
      prompt.each do |message|
        normalized = symbolize_keys(message)
        if normalized[:type].to_s == PLACEHOLDER_TYPE
          append_placeholder(normalized, kwargs, compiled, unresolved)
        else
          compiled << compile_message(normalized, kwargs)
        end
      end
      warn_unresolved(unresolved)
      compiled
    end

    private

    # Validate prompt data structure
    #
    # @param prompt_data [Hash] The prompt data to validate
    # @raise [ArgumentError] if validation fails
    def validate_prompt_data!(prompt_data)
      validate_base_prompt_data!(prompt_data)
      raise ArgumentError, "prompt must be an Array" unless prompt_data["prompt"].is_a?(Array)
    end

    # Compile a single role/content message with variable substitution
    #
    # @param normalized [Hash] Symbolized message hash
    # @param variables [Hash] Variables to substitute
    # @return [Hash] Compiled message with :role and :content as symbols
    def compile_message(normalized, variables)
      normalized.except(:type).merge(
        role: normalize_role(normalized[:role]),
        content: render(normalized[:content] || "", variables)
      )
    end

    # @api private
    def append_placeholder(message, variables, compiled, unresolved)
      name = message[:name].to_s
      found, value = lookup_placeholder(variables, name)
      return append_unresolved(name, compiled, unresolved) unless found

      expand_placeholder(name, value, variables, compiled)
    end

    # @api private
    def append_unresolved(name, compiled, unresolved)
      unresolved << name
      compiled << { type: PLACEHOLDER_TYPE, name: name }
    end

    # @api private
    def expand_placeholder(name, value, variables, compiled)
      return if value.is_a?(Array) && value.empty?

      unless value.is_a?(Array)
        raise ArgumentError, "Placeholder '#{name}' must contain an array of chat message hashes, got #{value.class}."
      end

      value.each { |entry| compiled << placeholder_message(entry, variables, name) }
    end

    # @api private
    def lookup_placeholder(variables, name)
      return [true, variables[name.to_sym]] if variables.key?(name.to_sym)
      return [true, variables[name]] if variables.key?(name)

      [false, nil]
    end

    # @api private
    def placeholder_message(message, variables, name)
      unless message.is_a?(Hash)
        raise ArgumentError,
              "Placeholder '#{name}' must contain an array of chat message hashes with role and content fields."
      end

      normalized = symbolize_keys(message)
      unless valid_placeholder_message?(normalized)
        raise ArgumentError,
              "Placeholder '#{name}' must contain an array of chat message hashes with role and content fields."
      end

      normalized.merge(
        role: normalize_role(normalized[:role]),
        content: render(normalized[:content] || "", variables)
      )
    end

    # @api private
    def render(content, variables)
      variables.empty? ? content : PromptRenderer.render(content, variables)
    end

    # @api private
    def valid_placeholder_message?(message)
      message.is_a?(Hash) &&
        message.key?(:role) &&
        !message[:role].to_s.empty? &&
        message.key?(:content)
    end

    # @api private
    def warn_unresolved(names)
      return if names.empty?

      unresolved_names = names.uniq.sort
      message = "Placeholders #{unresolved_names.inspect} have not been resolved. " \
                "Pass them as keyword arguments to compile()."
      warn_msg(message)
    end

    # @api private
    def warn_msg(message)
      Langfuse.configuration.logger.warn("Langfuse: #{message}")
    end

    # @api private
    def symbolize_keys(hash)
      hash.transform_keys(&:to_sym)
    end

    # Normalize role to symbol
    #
    # @param role [String, Symbol] The role
    # @return [Symbol] Normalized role as symbol
    def normalize_role(role)
      role.to_s.downcase.to_sym
    end
  end
end
