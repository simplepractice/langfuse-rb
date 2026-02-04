# frozen_string_literal: true

module Langfuse
  class DatasetItemClient
    include TimestampParser

    attr_reader :id, :dataset_id, :input, :expected_output, :metadata,
                :source_trace_id, :source_observation_id, :status,
                :created_at, :updated_at

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

    def active? = status == "ACTIVE"
    def archived? = status == "ARCHIVED"

    private

    def validate_item_data!(data)
      raise ArgumentError, "item_data must be a Hash" unless data.is_a?(Hash)
      raise ArgumentError, "item_data must include 'id' field" unless data.key?("id")
    end
  end
end
