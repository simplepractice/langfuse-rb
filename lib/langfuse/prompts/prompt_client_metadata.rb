# frozen_string_literal: true

module Langfuse
  # Shared metadata hydration for prompt client implementations.
  #
  # @api private
  module PromptClientMetadata
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

    # @return [String, Array<Hash>] Raw prompt template
    attr_reader :prompt

    # @return [String, nil] Optional commit message for this prompt version
    attr_reader :commit_message

    # @return [Hash, nil] Optional dependency resolution graph for composed prompts
    attr_reader :resolution_graph

    # @return [Boolean] Whether this client uses caller-provided fallback content
    attr_reader :is_fallback

    private

    # @api private
    def initialize_prompt_metadata(prompt_data, is_fallback:)
      validate_base_prompt_data!(prompt_data)

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

    # @api private
    def validate_base_prompt_data!(prompt_data)
      raise ArgumentError, "prompt_data must be a Hash" unless prompt_data.is_a?(Hash)
      raise ArgumentError, "prompt_data must include 'prompt' field" unless prompt_data.key?("prompt")
      raise ArgumentError, "prompt_data must include 'name' field" unless prompt_data.key?("name")
      raise ArgumentError, "prompt_data must include 'version' field" unless prompt_data.key?("version")
    end
  end
end
