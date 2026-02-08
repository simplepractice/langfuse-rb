# frozen_string_literal: true

module Langfuse
  # Orchestrates an experiment run: executes a task against each item,
  # runs evaluators, persists scores, and links dataset run items.
  #
  # This class is not intended to be instantiated directly. Use
  # {Client#run_experiment} or {DatasetClient#run_experiment} instead.
  #
  # @api private
  # rubocop:disable Metrics/ClassLength
  class ExperimentRunner
    # @param client [Client] Langfuse client for API calls
    # @param name [String] experiment/run name
    # @param items [Array<DatasetItemClient, Hash>] items to process
    # @param task [Proc] callable receiving an item, returning output
    # @param evaluators [Array<Proc>] item-level evaluators returning {Evaluation} or Array<{Evaluation}>
    # @param run_evaluators [Array<Proc>] run-level evaluators receiving all item results and returning {Evaluation}
    #   or Array<{Evaluation}>
    # @param metadata [Hash, nil] metadata attached to each trace
    # @param description [String, nil] run description for dataset run items
    # @param run_name [String, nil] explicit run name (defaults to "name - timestamp")
    # rubocop:disable Metrics/ParameterLists
    def initialize(client:, name:, items:, task:, evaluators: [], run_evaluators: [],
                   metadata: nil, description: nil, run_name: nil)
      @client = client
      @name = name
      @items = items.map { |item| normalize_item(item) }
      @task = task
      @evaluators = evaluators
      @run_evaluators = run_evaluators
      @metadata = metadata || {}
      @description = description
      @run_name = run_name || "#{name} - #{Time.now.utc.iso8601}"
      @logger = Langfuse.configuration.logger
      @dataset_run_id = nil
      @dataset_id = nil
    end
    # rubocop:enable Metrics/ParameterLists

    # @return [ExperimentResult]
    def execute
      item_results = @items.each_with_index.map { |item, index| process_item(item, index) }

      flush_all

      run_evals = execute_run_evaluators(item_results)
      flush_all if run_evals.any?

      ExperimentResult.new(
        name: @name,
        item_results: item_results,
        run_evaluations: run_evals,
        run_name: @run_name,
        description: @description,
        dataset_run_id: @dataset_run_id,
        dataset_run_url: build_dataset_run_url
      )
    end

    private

    def process_item(item, index)
      output, trace_id, observation_id, task_error = run_task_in_trace(item)

      if task_error
        log_task_failure(task_error, index)
        return ItemResult.new(item: item, trace_id: trace_id, observation_id: observation_id, error: task_error)
      end

      evaluations = execute_evaluators(item, output, trace_id)
      ItemResult.new(item: item, output: output, trace_id: trace_id,
                     observation_id: observation_id, evaluations: evaluations)
    end

    def run_task_in_trace(item)
      TracedExecution.call(
        trace_name: "experiment-#{@name}",
        input: item.input,
        metadata: @metadata,
        task: ->(_span) { @task.call(item) }
      ) do |span, trace_id|
        # Link before running task — server accepts forward-referenced trace IDs
        link_to_dataset_run(item, trace_id, span.id) if item.is_a?(DatasetItemClient)
      end
    end

    def execute_evaluators(item, output, trace_id)
      evaluations = @evaluators.flat_map do |evaluator|
        raw_result = call_evaluator(evaluator, item, output)
        normalize_evaluator_result(raw_result, source: "Evaluator")
      end

      evaluations.each { |evaluation| persist_score(evaluation, trace_id) }
      evaluations
    end

    def call_evaluator(evaluator, item, output)
      kwargs = { input: item.input, output: output, expected_output: item.expected_output, item: item }
      kwargs[:metadata] = item_metadata(item) if accepts_keyword?(evaluator, :metadata)
      evaluator.call(**kwargs)
    rescue StandardError => e
      @logger.warn("Evaluator failed: #{e.message}")
      nil
    end

    def persist_score(evaluation, trace_id)
      @client.create_score(
        name: evaluation.name, value: evaluation.value,
        trace_id: trace_id, comment: evaluation.comment, data_type: evaluation.data_type,
        config_id: evaluation.config_id, metadata: evaluation.metadata
      )
    rescue StandardError => e
      @logger.warn("Score persistence failed for '#{evaluation.name}': #{e.message}")
    end

    def execute_run_evaluators(item_results)
      evals = @run_evaluators.flat_map do |evaluator|
        raw_result = evaluator.call(item_results: item_results)
        normalize_evaluator_result(raw_result, source: "Run evaluator")
      rescue StandardError => e
        @logger.warn("Run evaluator failed: #{e.message}")
        []
      end

      evals.each { |eval| persist_run_score(eval) } if @dataset_run_id
      evals
    end

    def persist_run_score(evaluation)
      @client.create_score(
        name: evaluation.name, value: evaluation.value,
        comment: evaluation.comment, data_type: evaluation.data_type,
        dataset_run_id: @dataset_run_id,
        config_id: evaluation.config_id, metadata: evaluation.metadata
      )
    rescue StandardError => e
      @logger.warn("Run score persistence failed for '#{evaluation.name}': #{e.message}")
    end

    # Invariant: all items in a single run belong to the same dataset.
    def link_to_dataset_run(item, trace_id, observation_id)
      response = @client.create_dataset_run_item(
        dataset_item_id: item.id, run_name: @run_name,
        trace_id: trace_id, observation_id: observation_id,
        metadata: @metadata, run_description: @description
      )
      unless @dataset_run_id
        @dataset_run_id = response&.dig("datasetRunId")
        @dataset_id = item.dataset_id if @dataset_run_id
      end
      response
    rescue StandardError => e
      @logger.warn("Dataset run item linking failed: #{e.message}")
    end

    def flush_all
      @client.flush_scores
      Langfuse.force_flush(timeout: FLUSH_TIMEOUT)
    end

    # Wraps raw hashes into ExperimentItem; passes DatasetItemClient through unchanged.
    def normalize_item(item)
      return item if item.respond_to?(:input)
      unless item.is_a?(Hash)
        raise ArgumentError, "each data item must be a Hash or respond to #input, got #{item.class}"
      end

      ExperimentItem.new(
        input: local_item_value(item, :input),
        expected_output: local_item_value(item, :expected_output),
        metadata: local_item_value(item, :metadata)
      )
    end

    # @api private
    def local_item_value(item, key)
      return item[key] if item.key?(key)

      string_key = key.to_s
      item[string_key] if item.key?(string_key)
    end

    # @api private
    def normalize_evaluator_result(result, source:)
      return [] if result.nil?
      return [result] if result.is_a?(Evaluation)
      return [hash_to_evaluation(result)] if result.is_a?(Hash)
      return normalize_evaluation_array(result, source) if result.is_a?(Array)

      @logger.warn("#{source} returned unsupported result type: #{result.class}")
      []
    end

    # @api private
    def normalize_evaluation_array(result, source)
      result.each_with_object([]) do |entry, evaluations|
        if entry.is_a?(Evaluation)
          evaluations << entry
        elsif entry.is_a?(Hash)
          evaluations << hash_to_evaluation(entry)
        else
          @logger.warn("#{source} returned non-Evaluation entry: #{entry.class}")
        end
      end
    end

    # @api private
    def hash_to_evaluation(hash)
      h = hash.transform_keys(&:to_sym)
      Evaluation.new(
        name: h[:name], value: h[:value],
        comment: h[:comment], data_type: h.fetch(:data_type, :numeric),
        config_id: h[:config_id], metadata: h[:metadata]
      )
    end

    # @api private
    def accepts_keyword?(callable, keyword)
      return false unless callable.respond_to?(:parameters)

      callable.parameters.any? do |type, name|
        name == keyword && %i[key keyreq keyrest].include?(type)
      end
    end

    # @api private
    def item_metadata(item)
      item.respond_to?(:metadata) ? item.metadata : nil
    end

    def build_dataset_run_url
      return nil unless @dataset_run_id && @dataset_id

      @client.dataset_run_url(dataset_id: @dataset_id, dataset_run_id: @dataset_run_id)
    end

    # @api private
    def log_task_failure(task_error, index)
      message = task_error.respond_to?(:message) ? task_error.message : task_error.to_s
      @logger.warn("Task failed for item #{index + 1}: #{message}")
    end
  end
  # rubocop:enable Metrics/ClassLength
end
