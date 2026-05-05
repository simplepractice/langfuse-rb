# frozen_string_literal: true

require_relative "prompt_renderer"
require_relative "prompt_client_metadata"

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
    include PromptClientMetadata

    # Initialize a new text prompt client
    #
    # @param prompt_data [Hash] The prompt data from the API
    # @param is_fallback [Boolean] Whether this client wraps caller-provided fallback content
    # @raise [ArgumentError] if prompt data is invalid
    def initialize(prompt_data, is_fallback: false)
      initialize_prompt_metadata(prompt_data, is_fallback: is_fallback)
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
  end
end
