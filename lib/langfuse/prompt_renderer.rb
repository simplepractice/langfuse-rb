# frozen_string_literal: true

require "mustache"

module Langfuse
  # Renders prompt templates with Langfuse SDK-compatible variable semantics.
  #
  # @api private
  class PromptRenderer < Mustache
    # Langfuse variables are model input, not browser output; JS/Python SDKs substitute raw values.
    #
    # @param value [Object] Value to insert into the prompt
    # @return [String] Raw string representation
    def escape(value)
      value.to_s
    end
  end
end
