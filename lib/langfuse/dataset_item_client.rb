# frozen_string_literal: true

module Langfuse
  # Client wrapper for a Langfuse dataset item
  #
  # Wraps raw API response data for a single dataset item, providing typed
  # accessors and status query helpers.
  #
  # @example
  #   item = DatasetItemClient.new(api_response_hash)
  #   item.input            # => { "query" => "What is Ruby?" }
  #   item.active?          # => true
  #
  class DatasetItemClient
    include TimestampParser

    # @return [String] Unique identifier for the dataset item
    attr_reader :id

    # @return [String] Identifier of the parent dataset
    attr_reader :dataset_id

    # @return [Object, nil] Input data for the dataset item
    attr_reader :input

    # @return [Object, nil] Expected output for evaluation
    attr_reader :expected_output

    # @return [Hash] Additional metadata as key-value pairs
    attr_reader :metadata

    # @return [String, nil] Trace ID that produced this item
    attr_reader :source_trace_id

    # @return [String, nil] Observation ID that produced this item
    attr_reader :source_observation_id

    # @return [String] Item status (ACTIVE or ARCHIVED)
    attr_reader :status

    # @return [Time, nil] Timestamp when the item was created
    attr_reader :created_at

    # @return [Time, nil] Timestamp when the item was last updated
    attr_reader :updated_at

    # Initialize a new dataset item client from API response data
    #
    # @param item_data [Hash] Raw item data from the API
    # @raise [ArgumentError] if item_data is not a Hash or missing required fields
    def initialize(item_data)
      validate_item_data!(item_data)
      @id = item_data["id"]
      @dataset_id = item_data["datasetId"]
      @input = item_data["input"]
      @expected_output = item_data["expectedOutput"]
      @metadata = item_data["metadata"] || {}
      @source_trace_id = item_data["sourceTraceId"]
      @source_observation_id = item_data["sourceObservationId"]
      @status = item_data["status"] || "ACTIVE"
      @created_at = parse_timestamp(item_data["createdAt"])
      @updated_at = parse_timestamp(item_data["updatedAt"])
    end

    # Whether this item is active
    #
    # @return [Boolean]
    def active? = status == "ACTIVE"

    # Whether this item is archived
    #
    # @return [Boolean]
    def archived? = status == "ARCHIVED"

    private

    def validate_item_data!(data)
      raise ArgumentError, "item_data must be a Hash" unless data.is_a?(Hash)
      raise ArgumentError, "item_data must include 'id' field" unless data.key?("id")
    end
  end
end
