# frozen_string_literal: true

module Langfuse
  # Value object representing a single evaluation score
  #
  # Returned by evaluator callables during experiment runs. Wraps a score name,
  # value, and optional comment for persistence to the Langfuse API.
  #
  # @example Numeric evaluation
  #   Evaluation.new(name: "relevance", value: 0.85)
  #
  # @example Boolean evaluation with comment
  #   Evaluation.new(name: "is_valid", value: true, comment: "All fields present", data_type: :boolean)
  #
  # @example Categorical evaluation
  #   Evaluation.new(name: "sentiment", value: "positive", data_type: :categorical)
  class Evaluation
    # @return [String] the evaluation name
    # @return [Numeric, Integer, String] the evaluation value
    # @return [String, nil] optional comment
    # @return [Symbol] data type (:numeric, :boolean, or :categorical)
    # @return [String, nil] optional score config ID
    # @return [Hash, nil] optional metadata
    attr_reader :name, :value, :comment, :data_type, :config_id, :metadata

    # @param name [String] Score name (required, must be non-empty)
    # @param value [Numeric, Integer, String] Score value (type depends on data_type)
    # @param comment [String, nil] Optional comment describing the evaluation
    # @param data_type [Symbol] One of :numeric, :boolean, or :categorical
    # @param config_id [String, nil] Optional score config ID
    # @param metadata [Hash, nil] Optional metadata hash
    # @raise [ArgumentError] if name is nil or empty
    # @raise [ArgumentError] if data_type is not a valid score data type
    def initialize(name:, value:, comment: nil, data_type: :numeric, config_id: nil, metadata: nil)
      raise ArgumentError, "name is required" if name.to_s.empty?

      unless Types::SCORE_DATA_TYPES.key?(data_type)
        raise ArgumentError,
              "Invalid data_type: #{data_type}. Valid types: #{Types::VALID_SCORE_DATA_TYPES.join(', ')}"
      end

      validate_value!(value, data_type)

      @name = name
      @value = value
      @comment = comment
      @data_type = data_type
      @config_id = config_id
      @metadata = metadata
    end

    # @return [Hash{Symbol => Object}]
    def to_h
      { name: @name, value: @value, comment: @comment, data_type: @data_type,
        config_id: @config_id, metadata: @metadata }.compact
    end

    private

    def validate_value!(value, data_type)
      case data_type
      when :numeric
        raise ArgumentError, "Numeric value must be Numeric, got #{value.class}" unless value.is_a?(Numeric)
      when :boolean
        unless [true, false, 0, 1].include?(value)
          raise ArgumentError, "Boolean value must be true/false or 0/1, got #{value.inspect}"
        end
      when :categorical
        raise ArgumentError, "Categorical value must be a String, got #{value.class}" unless value.is_a?(String)
      end
    end
  end
end
