# frozen_string_literal: true

module Langfuse
  # Client wrapper for a Langfuse dataset
  #
  # Provides read access to dataset fields and the ability to run experiments
  # against the dataset's items. Returned by {Client#get_dataset} and
  # {Client#create_dataset}.
  #
  # @example Fetching and iterating items
  #   dataset = client.get_dataset("qa-pairs")
  #   dataset.items.each { |item| puts item.input }
  #
  # @example Running an experiment
  #   dataset.run_experiment(name: "v1", task: ->(item) { llm_call(item.input) })
  class DatasetClient
    include TimestampParser

    # @return [String] dataset ID
    # @return [String] dataset name
    # @return [String, nil] optional description
    # @return [Hash] metadata hash
    # @return [Time, nil] creation timestamp
    # @return [Time, nil] last update timestamp
    attr_reader :id, :name, :description, :metadata, :created_at, :updated_at

    # @param dataset_data [Hash] raw dataset hash from the API (string keys)
    # @param client [Client, nil] Langfuse client for API operations
    # @raise [ArgumentError] if dataset_data is not a Hash or missing required fields
    def initialize(dataset_data, client: nil)
      validate_dataset_data!(dataset_data)
      @id = dataset_data["id"]
      @name = dataset_data["name"]
      @description = dataset_data["description"]
      @metadata = dataset_data["metadata"] || {}
      @created_at = parse_timestamp(dataset_data["createdAt"])
      @updated_at = parse_timestamp(dataset_data["updatedAt"])
      @raw_items = dataset_data["items"] || []
      @client = client
    end

    # @return [Array<DatasetItemClient>]
    def items
      @items ||= if @raw_items.empty? && @client
                   @client.list_dataset_items(dataset_name: @name)
                 else
                   @raw_items.map { |item_data| DatasetItemClient.new(item_data, client: @client) }
                 end
    end

    # Run an experiment against all items in this dataset
    #
    # @param name [String] experiment/run name (required)
    # @param task [Proc] callable receiving a {DatasetItemClient}, returning output
    # @param description [String, nil] optional run description
    # @param evaluators [Array<Proc>] item-level evaluators returning {Evaluation} or Array<{Evaluation}>
    # @param run_evaluators [Array<Proc>] run-level evaluators receiving all item results and returning
    #   {Evaluation} or Array<{Evaluation}>
    # @param metadata [Hash, nil] metadata attached to each trace
    # @param run_name [String, nil] explicit run name (defaults to "name - timestamp")
    # @return [ExperimentResult]
    # @raise [ArgumentError] if client was not provided at initialization
    # rubocop:disable Metrics/ParameterLists
    def run_experiment(name:, task:, description: nil, evaluators: [], run_evaluators: [],
                       metadata: nil, run_name: nil)
      raise ArgumentError, "client is required for this operation" unless @client

      @client.run_experiment(
        name: name,
        data: items,
        task: task,
        evaluators: evaluators,
        run_evaluators: run_evaluators,
        metadata: metadata,
        description: description,
        run_name: run_name
      )
    end
    # rubocop:enable Metrics/ParameterLists

    private

    def validate_dataset_data!(data)
      raise ArgumentError, "dataset_data must be a Hash" unless data.is_a?(Hash)
      raise ArgumentError, "dataset_data must include 'id' field" unless data.key?("id")
      raise ArgumentError, "dataset_data must include 'name' field" unless data.key?("name")
    end
  end
end
