# frozen_string_literal: true

module Langfuse
  # Shared masking helper used before payloads are serialized into OTel attributes.
  #
  # @api private
  module PayloadMasker
    MASK_FAILURE_PLACEHOLDER = "<fully masked due to failed mask function>"
    MASKABLE_KEYS = [[:input, "input"], [:output, "output"], [:metadata, "metadata"]].freeze

    def self.mask_fields(attrs)
      attrs.dup.tap do |masked|
        MASKABLE_KEYS.each do |sym_key, str_key|
          masked[sym_key] = mask(masked[sym_key]) if masked.key?(sym_key)
          masked[str_key] = mask(masked[str_key]) if masked.key?(str_key)
        end
      end
    end

    def self.mask(data)
      mask = Langfuse.configuration.mask
      return data unless mask
      return nil if data.nil?

      mask.call(data: duplicate(data))
    rescue StandardError => e
      log_failure(e)
      MASK_FAILURE_PLACEHOLDER
    end

    def self.duplicate(data, visited = {}.compare_by_identity)
      case data
      when Hash
        duplicate_hash(data, visited)
      when Array
        duplicate_array(data, visited)
      else
        duplicate_leaf(data)
      end
    end

    def self.log_failure(error)
      Langfuse.configuration.logger.warn(
        "Langfuse: mask function failed (#{error.class}); using placeholder"
      )
    rescue StandardError
      nil
    end

    def self.duplicate_hash(data, visited)
      return visited[data] if visited.key?(data)

      copy = {}
      visited[data] = copy
      data.each do |key, value|
        copy[duplicate_leaf(key)] = duplicate(value, visited)
      end
      copy
    end

    def self.duplicate_array(data, visited)
      return visited[data] if visited.key?(data)

      copy = []
      visited[data] = copy
      data.each { |value| copy << duplicate(value, visited) }
      copy
    end

    def self.duplicate_leaf(value)
      case value
      when Symbol, Numeric, NilClass, TrueClass, FalseClass
        value
      else
        value.dup
      end
    rescue StandardError
      value
    end

    private_class_method :duplicate, :duplicate_hash, :duplicate_array, :duplicate_leaf, :log_failure
  end
end
