# frozen_string_literal: true

module Langfuse
  # Client wrapper for a single Langfuse dataset item
  #
  # Provides read access to item fields and operations to link items to traces
  # or run tasks within a traced context. Returned by {Client#get_dataset_item},
  # {Client#create_dataset_item}, and {DatasetClient#items}.
  #
  # @example Linking to an existing trace
  #   item.link(trace_id: "abc123", run_name: "eval-v1")
  #
  # @example Running a task with auto-linking
  #   item.run(run_name: "eval-v1") do |span|
  #     my_llm_call(item.input)
  #   end
  class DatasetItemClient
    include TimestampParser

    # @return [String] item ID
    # @return [String] parent dataset ID
    # @return [Object, nil] input data
    # @return [Object, nil] expected output for evaluation
    # @return [Hash] metadata hash
    # @return [String, nil] source trace ID
    # @return [String, nil] source observation ID
    # @return [String] item status ("ACTIVE" or "ARCHIVED")
    # @return [Time, nil] creation timestamp
    # @return [Time, nil] last update timestamp
    attr_reader :id, :dataset_id, :input, :expected_output, :metadata,
                :source_trace_id, :source_observation_id, :status,
                :created_at, :updated_at

    # @param item_data [Hash] raw item hash from the API (string keys)
    # @param client [Client, nil] Langfuse client for API operations
    # @raise [ArgumentError] if item_data is not a Hash or missing required fields
    def initialize(item_data, client: nil)
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
      @client = client
    end

    # @return [Boolean] true if the item is active
    def active? = status == "ACTIVE"

    # @return [Boolean] true if the item is archived
    def archived? = status == "ARCHIVED"

    # Link this dataset item to a trace within a named run
    #
    # @param trace_id [String] trace ID to link
    # @param run_name [String] run name for grouping
    # @param observation_id [String, nil] optional observation ID
    # @param metadata [Hash, nil] optional metadata
    # @param run_description [String, nil] optional run description
    # @return [Hash] the created dataset run item data
    # @raise [ArgumentError] if client was not provided at initialization
    def link(trace_id:, run_name:, observation_id: nil, metadata: nil, run_description: nil)
      require_client!
      @client.create_dataset_run_item(
        dataset_item_id: @id,
        run_name: run_name,
        trace_id: trace_id,
        observation_id: observation_id,
        metadata: metadata,
        run_description: run_description
      )
    end

    # Run a block within a traced context and auto-link to this dataset item
    #
    # Lower-level alternative to {Client#run_experiment} for single-item
    # execution with direct span access. Matches Python SDK's
    # `item.run()` context manager pattern.
    #
    # Executes the block inside an observed span, flushes the trace, then
    # creates a dataset run item linking this item to the resulting trace.
    #
    # @param run_name [String] run name for grouping
    # @param run_description [String, nil] optional run description
    # @param run_metadata [Hash, nil] optional metadata for the trace
    # @yield [span] block executed within the traced context
    # @yieldparam span [BaseObservation] the active span
    # @return [Object] the block's return value
    # @raise [ArgumentError] if client was not provided or block is missing
    # @raise [StandardError] re-raises any error from the block after flushing and linking
    def run(run_name:, run_description: nil, run_metadata: nil, &block)
      require_client!
      raise ArgumentError, "block is required" unless block

      output, trace_id, observation_id, task_error = execute_in_trace(run_name, run_metadata, &block)
      Langfuse.force_flush(timeout: FLUSH_TIMEOUT)

      link(trace_id: trace_id, observation_id: observation_id, run_name: run_name,
           run_description: run_description, metadata: run_metadata)
      raise task_error if task_error

      output
    end

    private

    def execute_in_trace(run_name, run_metadata, &block)
      TracedExecution.call(
        trace_name: "dataset-run-#{run_name}",
        input: @input,
        metadata: run_metadata || {},
        task: block
      )
    end

    def require_client!
      raise ArgumentError, "client is required for this operation" unless @client
    end

    def validate_item_data!(data)
      raise ArgumentError, "item_data must be a Hash" unless data.is_a?(Hash)
      raise ArgumentError, "item_data must include 'id' field" unless data.key?("id")
    end
  end
end
