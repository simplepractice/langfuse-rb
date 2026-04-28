# frozen_string_literal: true

require_relative "prompt_renderer"

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
    # @return [String] Prompt name
    attr_reader :name

    # @return [Integer] Prompt version number
    attr_reader :version

    # @return [Array<String>] Labels assigned to this prompt
    attr_reader :labels

    # @return [Array<String>] Tags assigned to this prompt
    attr_reader :tags

    # @return [Hash] Prompt configuration
    attr_reader :config

    # @return [Array<Hash>] Array of message hashes and placeholder entries
    attr_reader :prompt

    # @return [Boolean] Whether this client uses caller-provided fallback content
    attr_reader :is_fallback

    # Initialize a new chat prompt client
    #
    # @param prompt_data [Hash] The prompt data from the API
    # @param is_fallback [Boolean] Whether this client wraps caller-provided fallback content
    # @raise [ArgumentError] if prompt data is invalid
    def initialize(prompt_data, is_fallback: false)
      validate_prompt_data!(prompt_data)

      @name = prompt_data["name"]
      @version = prompt_data["version"]
      @prompt = prompt_data["prompt"]
      @labels = prompt_data["labels"] || []
      @tags = prompt_data["tags"] || []
      @config = prompt_data["config"] || {}
      @is_fallback = is_fallback
    end

    # Compile the chat prompt with variable substitution and message placeholders
    #
    # Returns an array of message hashes with roles and compiled content.
    # Placeholder entries are resolved from keyword arguments using the
    # Langfuse Python SDK semantics: arrays are expanded, empty arrays are
    # skipped, unresolved placeholders stay in the output, and malformed values
    # degrade to a synthetic message with a warning.
    #
    # @param kwargs [Hash] Variables and placeholder values to compile
    # @return [Array<Hash>] Array of compiled messages and unresolved placeholders
    #
    # @example
    #   chat_prompt.compile(name: "Alice", topic: "Ruby")
    #   # => [
    #   #   { role: :system, content: "You are a helpful assistant." },
    #   #   { role: :user, content: "Hello Alice, let's discuss Ruby!" }
    #   # ]
    def compile(**kwargs)
      unresolved_placeholders = []
      compiled_messages = prompt.flat_map do |message|
        if placeholder_message?(message)
          compile_placeholder(message, kwargs, unresolved_placeholders)
        else
          [compile_message(message, kwargs)]
        end
      end

      warn_unresolved_placeholders(unresolved_placeholders)
      compiled_messages
    end

    private

    # Validate prompt data structure
    #
    # @param prompt_data [Hash] The prompt data to validate
    # @raise [ArgumentError] if validation fails
    def validate_prompt_data!(prompt_data)
      raise ArgumentError, "prompt_data must be a Hash" unless prompt_data.is_a?(Hash)
      raise ArgumentError, "prompt_data must include 'prompt' field" unless prompt_data.key?("prompt")
      raise ArgumentError, "prompt_data must include 'name' field" unless prompt_data.key?("name")
      raise ArgumentError, "prompt_data must include 'version' field" unless prompt_data.key?("version")
      raise ArgumentError, "prompt must be an Array" unless prompt_data["prompt"].is_a?(Array)
    end

    # Compile a single role/content message with variable substitution
    #
    # @param message [Hash] The message with role and content
    # @param variables [Hash] Variables to substitute
    # @return [Hash] Compiled message with :role and :content as symbols
    def compile_message(message, variables)
      normalized = symbolize_keys(message)
      content = normalized[:content] || ""
      compiled_content = variables.empty? ? content : PromptRenderer.render(content, variables)

      normalized.except(:type).merge(
        role: normalize_role(normalized[:role]),
        content: compiled_content
      )
    end

    # @api private
    def compile_placeholder(message, variables, unresolved_placeholders)
      placeholder_name = placeholder_name(message)
      found, value = placeholder_value(variables, placeholder_name)

      unless found
        unresolved_placeholders << placeholder_name
        return [placeholder_entry(placeholder_name)]
      end

      return [] if value.is_a?(Array) && value.empty?
      return malformed_placeholder_value(placeholder_name, value) unless value.is_a?(Array)

      value.flat_map do |placeholder_message|
        compile_placeholder_message(placeholder_name, placeholder_message, value, variables)
      end
    end

    # @api private
    def compile_placeholder_message(placeholder_name, message, placeholder_value, variables)
      return malformed_placeholder_message(placeholder_name, placeholder_value) unless message.is_a?(Hash)

      normalized = symbolize_keys(message)
      content = normalized.fetch(:content, "")
      compiled_content = variables.empty? ? content : PromptRenderer.render(content, variables)

      [
        normalized.merge(
          role: normalize_role(normalized.fetch(:role, "NOT_GIVEN")),
          content: compiled_content
        )
      ]
    end

    # @api private
    def malformed_placeholder_value(placeholder_name, value)
      warn_placeholder("Placeholder '#{placeholder_name}' must contain an array of chat messages, got #{value.class}.")
      [not_given_message(value.to_s)]
    end

    # @api private
    def malformed_placeholder_message(placeholder_name, placeholder_value)
      warn_placeholder(
        "Placeholder '#{placeholder_name}' should contain chat message hashes. Appended as string."
      )
      [not_given_message(placeholder_value.to_s)]
    end

    # @api private
    def placeholder_message?(message)
      message.is_a?(Hash) && value_for(message, :type).to_s == "placeholder"
    end

    # @api private
    def placeholder_name(message)
      value_for(message, :name).to_s
    end

    # @api private
    def placeholder_entry(name)
      { type: "placeholder", name: name }
    end

    # @api private
    def not_given_message(content)
      { role: :not_given, content: content }
    end

    # @api private
    def placeholder_value(variables, name)
      symbol_name = name.to_sym
      return [true, variables[name]] if variables.key?(name)
      return [true, variables[symbol_name]] if variables.key?(symbol_name)

      [false, nil]
    end

    # @api private
    def warn_unresolved_placeholders(names)
      return if names.empty?

      warn_placeholder(
        "Placeholders #{names.inspect} have not been resolved. Pass them as keyword arguments to compile()."
      )
    end

    # @api private
    def warn_placeholder(message)
      return unless Langfuse.respond_to?(:configuration)

      Langfuse.configuration.logger.warn("Langfuse: #{message}")
    end

    # @api private
    def symbolize_keys(hash)
      hash.transform_keys do |key|
        key.to_sym
      rescue StandardError
        key
      end
    end

    # @api private
    def value_for(hash, key)
      hash[key.to_s] || hash[key.to_sym]
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
