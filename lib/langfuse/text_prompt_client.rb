# frozen_string_literal: true

require_relative "prompt_renderer"

module Langfuse
  # Text prompt client for compiling text prompts with variable substitution
  #
  # Handles text-based prompts from Langfuse, providing Mustache templating
  # for variable substitution.
  #
  # @example Basic usage
  #   prompt_data = api_client.get_prompt("greeting")
  #   text_prompt = Langfuse::TextPromptClient.new(prompt_data)
  #   text_prompt.compile(variables: { name: "Alice" })
  #   # => "Hello Alice!"
  #
  # @example Accessing metadata
  #   text_prompt.name      # => "greeting"
  #   text_prompt.version   # => 1
  #   text_prompt.labels    # => ["production"]
  #
  class TextPromptClient
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

    # @return [String] Raw prompt template
    attr_reader :prompt

    # @return [String, nil] Optional commit message for this prompt version
    attr_reader :commit_message

    # @return [Hash, nil] Optional dependency resolution graph for composed prompts
    attr_reader :resolution_graph

    # @return [Boolean] Whether this client uses caller-provided fallback content
    attr_reader :is_fallback

    # Initialize a new text prompt client
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
      @commit_message = prompt_data["commitMessage"]
      @resolution_graph = prompt_data["resolutionGraph"]
      @is_fallback = is_fallback
    end

    # @return [String] Prompt type ("text")
    def type
      "text"
    end

    # Compile the prompt with variable substitution
    #
    # @param kwargs [Hash] Variables to substitute in the template (as keyword arguments)
    # @return [String] The compiled prompt text
    # @raise [ArgumentError] if variables cannot be rendered
    #
    # @example
    #   text_prompt.compile(name: "Alice", greeting: "Hi")
    #   # => "Hi Alice! Welcome."
    def compile(**kwargs)
      return prompt if kwargs.empty?

      PromptRenderer.render(prompt, kwargs)
    end

    private

    def validate_prompt_data!(prompt_data)
      raise ArgumentError, "prompt_data must be a Hash" unless prompt_data.is_a?(Hash)
      raise ArgumentError, "prompt_data must include 'prompt' field" unless prompt_data.key?("prompt")
      raise ArgumentError, "prompt_data must include 'name' field" unless prompt_data.key?("name")
      raise ArgumentError, "prompt_data must include 'version' field" unless prompt_data.key?("version")
    end
  end
end
