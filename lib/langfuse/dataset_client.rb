# frozen_string_literal: true

module Langfuse
  # Client wrapper for a Langfuse dataset
  #
  # Wraps raw API response data for a dataset, providing typed accessors
  # and lazy-loaded dataset items.
  #
  # @example
  #   dataset = DatasetClient.new(api_response_hash)
  #   dataset.name      # => "my-eval-set"
  #   dataset.items     # => [DatasetItemClient, ...]
  #
  class DatasetClient
    include TimestampParser

    # @return [String] Unique identifier for the dataset
    attr_reader :id

    # @return [String] Human-readable name of the dataset
    attr_reader :name

    # @return [String, nil] Optional description of the dataset
    attr_reader :description

    # @return [Hash] Additional metadata as key-value pairs
    attr_reader :metadata

    # @return [Time, nil] Timestamp when the dataset was created
    attr_reader :created_at

    # @return [Time, nil] Timestamp when the dataset was last updated
    attr_reader :updated_at

    # Initialize a new dataset client from API response data
    #
    # @param dataset_data [Hash] Raw dataset data from the API
    # @raise [ArgumentError] if dataset_data is not a Hash or missing required fields
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

    # Lazily-parsed dataset items
    #
    # @return [Array<DatasetItemClient>] Items belonging to this dataset
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
