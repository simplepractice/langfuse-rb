# frozen_string_literal: true

module Langfuse
  # Normalizes score values to the wire representation expected by Langfuse.
  # @api private
  module ScoreValue
    TEXT_LENGTH_RANGE = (1..500)
    private_constant :TEXT_LENGTH_RANGE

    # @param value [Object] raw score value
    # @param data_type [Symbol] score data type
    # @return [Numeric, String] normalized score value
    # @raise [ArgumentError] if the value does not match the data type
    def self.normalize(value, data_type)
      case data_type
      when :numeric then numeric(value)
      when :boolean then boolean(value)
      when :categorical then string(value, "Categorical")
      when :text then text(value)
      when :correction then string(value, "Correction")
      else raise ArgumentError, "Invalid data_type: #{data_type}"
      end
    end

    def self.numeric(value)
      raise ArgumentError, "Numeric value must be Numeric, got #{value.class}" unless value.is_a?(Numeric)

      value
    end
    private_class_method :numeric

    def self.boolean(value)
      case value
      when true, 1 then 1
      when false, 0 then 0
      else raise ArgumentError, "Boolean value must be true/false or 0/1, got #{value.inspect}"
      end
    end
    private_class_method :boolean

    def self.text(value)
      string(value, "Text")
      unless TEXT_LENGTH_RANGE.cover?(value.length)
        raise ArgumentError, "Text value must contain 1 to 500 characters, got #{value.length}"
      end

      value
    end
    private_class_method :text

    def self.string(value, label)
      raise ArgumentError, "#{label} value must be a String, got #{value.class}" unless value.is_a?(String)

      value
    end
    private_class_method :string
  end
end
