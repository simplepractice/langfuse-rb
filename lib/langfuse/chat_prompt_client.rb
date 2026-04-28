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
    PLACEHOLDER_TYPE = "placeholder"

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
      raise ArgumentError, "prompt_data must be a Hash" unless prompt_data.is_a?(Hash)
      raise ArgumentError, "prompt_data must include 'prompt' field" unless prompt_data.key?("prompt")
      raise ArgumentError, "prompt_data must include 'name' field" unless prompt_data.key?("name")
      raise ArgumentError, "prompt_data must include 'version' field" unless prompt_data.key?("version")
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
        warn_msg("Placeholder '#{name}' must contain an array of chat messages, got #{value.class}.")
        compiled << not_given(value.to_s)
        return
      end

      value.each { |entry| compiled << placeholder_message(entry, variables, name, value) }
    end

    # @api private
    def lookup_placeholder(variables, name)
      return [true, variables[name.to_sym]] if variables.key?(name.to_sym)
      return [true, variables[name]] if variables.key?(name)

      [false, nil]
    end

    # @api private
    def placeholder_message(message, variables, name, raw_value)
      unless message.is_a?(Hash)
        warn_msg("Placeholder '#{name}' should contain chat message hashes. Appended as string.")
        return not_given(raw_value.to_s)
      end
      normalized = symbolize_keys(message)
      normalized.merge(
        role: normalize_role(normalized.fetch(:role, "NOT_GIVEN")),
        content: render(normalized.fetch(:content, ""), variables)
      )
    end

    # @api private
    def render(content, variables)
      variables.empty? ? content : PromptRenderer.render(content, variables)
    end

    # @api private
    def not_given(content)
      { role: :not_given, content: content }
    end

    # @api private
    def warn_unresolved(names)
      return if names.empty?

      warn_msg("Placeholders #{names.inspect} have not been resolved. Pass them as keyword arguments to compile().")
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
