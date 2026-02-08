# frozen_string_literal: true

module Langfuse
  # Aggregate result of a full experiment run
  #
  # Collects all {ItemResult} instances and run-level evaluations produced
  # by {ExperimentRunner#execute}. Provides convenience accessors for
  # successes/failures and a human-readable summary via {#format}.
  #
  # @example Inspecting results
  #   result = client.run_experiment(name: "qa-v1", dataset_name: "qa", task: my_task)
  #   puts result.format
  #   result.successes.size  # => 8
  #   result.failures.size   # => 0
  class ExperimentResult
    # @return [String] the experiment/run name
    # @return [String, nil] auto-generated run name (name + timestamp)
    # @return [String, nil] run description
    # @return [Array<ItemResult>] per-item results (all items, including failures)
    # @return [Array<Evaluation>] run-level evaluation results
    # @return [String, nil] dataset run ID from the server
    # @return [String, nil] URL to the dataset run in Langfuse UI
    attr_reader :name, :run_name, :description, :item_results, :run_evaluations,
                :dataset_run_id, :dataset_run_url

    # @param name [String] experiment/run name
    # @param item_results [Array<ItemResult>] per-item results
    # @param run_evaluations [Array<Evaluation>] run-level evaluations
    # @param run_name [String, nil] auto-generated run name
    # @param description [String, nil] run description
    # @param dataset_run_id [String, nil] dataset run ID from the server
    # @param dataset_run_url [String, nil] URL to the dataset run in Langfuse UI
    # rubocop:disable Metrics/ParameterLists
    def initialize(name:, item_results:, run_evaluations: [], run_name: nil, description: nil,
                   dataset_run_id: nil, dataset_run_url: nil)
      @name = name
      @item_results = item_results
      @run_evaluations = run_evaluations
      @run_name = run_name
      @description = description
      @dataset_run_id = dataset_run_id
      @dataset_run_url = dataset_run_url
    end
    # rubocop:enable Metrics/ParameterLists

    # @return [Array<ItemResult>] items that completed without error
    def successes = item_results.select(&:success?)

    # @return [Array<ItemResult>] items that raised an error
    def failures = item_results.select(&:failed?)

    SEPARATOR = "\u2500" * 50

    # @param include_item_results [Boolean] whether to show per-item detail
    # @return [String] multi-line formatted report
    def format(include_item_results: false)
      lines = []
      append_item_section(lines, include_item_results)
      lines << SEPARATOR
      append_summary(lines)
      append_evaluation_names(lines)
      append_average_scores(lines)
      append_run_evaluation_lines(lines)
      lines.join("\n")
    end

    private

    def append_item_section(lines, include_detail)
      if include_detail
        item_results.each_with_index { |r, i| append_item_detail(lines, i + 1, r) }
      else
        lines << "Individual Results: Hidden (#{item_results.size} items)"
        lines << "Set include_item_results: true to view them"
      end
    end

    def append_item_detail(lines, number, result)
      lines << "#{number}. Item #{number}:"
      if result.failed?
        lines << "   Error: #{result.error.message}"
      else
        append_item_io(lines, result)
        append_item_scores(lines, result)
      end
      lines << "   Trace ID: #{result.trace_id}" if result.trace_id
      lines << ""
    end

    def append_item_io(lines, result)
      lines << "   Input:    #{format_value(result.item.input)}"
      lines << "   Expected: #{format_value(result.item.expected_output)}"
      lines << "   Actual:   #{format_value(result.output)}"
    end

    def append_item_scores(lines, result)
      return unless result.evaluations.any?

      lines << "   Scores:"
      result.evaluations.each do |eval|
        lines << "     \u2022 #{eval.name}: #{format_score(eval.value)}"
        lines << "       \u{1F4AD} #{eval.comment}" if eval.comment
      end
    end

    def append_summary(lines)
      lines << "\u{1F9EA} Experiment: #{@name}"
      lines << "\u{1F4CB} Run name: #{@run_name}" if @run_name
      lines << "\u{1F4DD} Description: #{@description}" if @description
      lines << "\u{1F517} Dataset run: #{@dataset_run_url}" if @dataset_run_url
      lines << "#{item_results.size} items"
    end

    def append_evaluation_names(lines)
      names = collect_evaluation_names
      return if names.empty?

      lines << "Evaluations:"
      names.each { |n| lines << "  \u2022 #{n}" }
    end

    def append_average_scores(lines)
      averages = compute_average_scores
      return if averages.empty?

      lines << "Average Scores:"
      averages.each { |name, avg| lines << "  \u2022 #{name}: #{format_score(avg)}" }
    end

    def append_run_evaluation_lines(lines)
      return unless run_evaluations.any?

      lines << "Run Evaluations:"
      run_evaluations.each do |eval|
        lines << "  \u2022 #{eval.name}: #{format_score(eval.value)}"
        lines << "    \u{1F4AD} #{eval.comment}" if eval.comment
      end
    end

    # @return [Array<String>] unique evaluation names across all items
    def collect_evaluation_names
      item_results
        .flat_map { |r| r.evaluations.map(&:name) }
        .uniq
    end

    # @return [Hash{String => Float}] mean of each numeric evaluation
    def compute_average_scores
      scores_by_name = Hash.new { |h, k| h[k] = [] }
      item_results.each do |r|
        r.evaluations.each do |eval|
          scores_by_name[eval.name] << eval.value if eval.value.is_a?(Numeric)
        end
      end
      scores_by_name.transform_values { |vals| vals.sum.to_f / vals.size }
    end

    def format_value(val)
      str = val.to_s
      str.length > 50 ? "#{str[0, 47]}..." : str
    end

    def format_score(val)
      val.is_a?(Numeric) ? Kernel.format("%.3f", val) : val.to_s
    end
  end
end
