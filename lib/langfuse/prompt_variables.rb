# frozen_string_literal: true

require "mustache"

module Langfuse
  # Extracts referenced variables from parsed Mustache templates.
  #
  # @api private
  class PromptVariables
    TAG_TYPES = %i[etag utag].freeze
    SECTION_TYPES = %i[section inverted_section].freeze

    class << self
      # @api private
      def extract(template)
        tokens = Mustache::Template.new(template).tokens
        collect(tokens, []).reject(&:empty?).uniq
      end

      private

      def collect(tokens, scope)
        tokens.each_with_object([]) do |token, variables|
          next unless token.is_a?(Array)

          variables.concat(token.first == :mustache ? from_tag(token, scope) : collect(token, scope))
        end
      end

      def from_tag(token, scope)
        return variable_path(token, scope) if TAG_TYPES.include?(token[1])
        return section_paths(token, scope) if SECTION_TYPES.include?(token[1])

        []
      end

      def variable_path(token, scope)
        path = scoped_path(token, scope)
        path.empty? ? [] : [path.join(".")]
      end

      def section_paths(token, scope)
        section_path = scoped_path(token, scope)
        [section_path.join("."), *collect(token[4], section_path)]
      end

      def scoped_path(token, scope)
        segments = token.dig(2, 2)
        segments == ["."] ? scope : scope + segments
      end
    end
  end
end
