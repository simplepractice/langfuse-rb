# frozen_string_literal: true

module Langfuse
  class DatasetClient
    include TimestampParser

    attr_reader :id, :name, :description, :metadata, :created_at, :updated_at

    def initialize(dataset_data)
      validate_dataset_data!(dataset_data)
      @id = dataset_data["id"]
      @name = dataset_data["name"]
      @description = dataset_data["description"]
      @metadata = dataset_data["metadata"] || {}
      @created_at = parse_timestamp(dataset_data["createdAt"])
      @updated_at = parse_timestamp(dataset_data["updatedAt"])
      @raw_items = dataset_data["items"] || []
    end

    def items
      @items ||= @raw_items.map { |item_data| DatasetItemClient.new(item_data) }
    end

    private

    def validate_dataset_data!(data)
      raise ArgumentError, "dataset_data must be a Hash" unless data.is_a?(Hash)
      raise ArgumentError, "dataset_data must include 'id' field" unless data.key?("id")
      raise ArgumentError, "dataset_data must include 'name' field" unless data.key?("name")
    end
  end
end
