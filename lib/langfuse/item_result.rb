# frozen_string_literal: true

module Langfuse
  # Result of processing a single item in an experiment run
  #
  # Captures the task output, associated trace, evaluations, and any errors
  # for one dataset item or data hash processed by {ExperimentRunner}.
  #
  # @example Successful result
  #   result.success?     # => true
  #   result.output       # => "Hello Alice!"
  #   result.evaluations  # => [#<Evaluation name="relevance" value=0.9>]
  #
  # @example Failed result
  #   result.failed?        # => true
  #   result.error.message  # => "API timeout"
  class ItemResult
    # @return [DatasetItemClient, ExperimentItem] the original input item
    # @return [Object, nil] task output, nil on failure
    # @return [String, nil] trace ID for the task execution
    # @return [String, nil] observation (span) ID for the task execution
    # @return [Array<Evaluation>] item-level evaluation results
    # @return [StandardError, nil] error raised during task execution
    attr_reader :item, :output, :trace_id, :observation_id, :evaluations, :error

    # @param item [DatasetItemClient, ExperimentItem] the input item
    # @param output [Object, nil] task output
    # @param trace_id [String, nil] trace ID from the observed execution
    # @param observation_id [String, nil] observation (span) ID from the observed execution
    # @param evaluations [Array<Evaluation>] item-level evaluation results
    # @param error [StandardError, nil] error if the task failed
    def initialize(item:, output: nil, trace_id: nil, observation_id: nil, evaluations: [], error: nil)
      @item = item
      @output = output
      @trace_id = trace_id
      @observation_id = observation_id
      @evaluations = evaluations
      @error = error
    end

    # @return [Boolean] true if the task completed without error
    def success? = error.nil?

    # @return [Boolean] true if the task raised an error
    def failed? = !success?
  end
end
