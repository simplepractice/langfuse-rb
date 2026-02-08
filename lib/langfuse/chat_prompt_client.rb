# frozen_string_literal: true

require "mustache"

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

    # @return [Array<Hash>] Array of message hashes with role and content
    attr_reader :prompt

    # Initialize a new chat prompt client
    #
    # @param prompt_data [Hash] The prompt data from the API
    # @raise [ArgumentError] if prompt data is invalid
    def initialize(prompt_data)
      validate_prompt_data!(prompt_data)

      @name = prompt_data["name"]
      @version = prompt_data["version"]
      @prompt = prompt_data["prompt"]
      @labels = prompt_data["labels"] || []
      @tags = prompt_data["tags"] || []
      @config = prompt_data["config"] || {}
    end

    # Compile the chat prompt with variable substitution
    #
    # Returns an array of message hashes with roles and compiled content.
    # Each message in the prompt will have its content compiled with the
    # provided variables using Mustache templating.
    #
    # @param kwargs [Hash] Variables to substitute in message templates (as keyword arguments)
    # @return [Array<Hash>] Array of compiled messages with :role and :content keys
    #
    # @example
    #   chat_prompt.compile(name: "Alice", topic: "Ruby")
    #   # => [
    #   #   { role: :system, content: "You are a helpful assistant." },
    #   #   { role: :user, content: "Hello Alice, let's discuss Ruby!" }
    #   # ]
    def compile(**kwargs)
      prompt.map do |message|
        compile_message(message, kwargs)
      end
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

    # Compile a single message with variable substitution
    #
    # @param message [Hash] The message with role and content
    # @param variables [Hash] Variables to substitute
    # @return [Hash] Compiled message with :role and :content as symbols
    def compile_message(message, variables)
      content = message["content"] || ""
      compiled_content = variables.empty? ? content : Mustache.render(content, variables)

      {
        role: normalize_role(message["role"]),
        content: compiled_content
      }
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
