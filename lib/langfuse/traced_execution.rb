# frozen_string_literal: true

module Langfuse
  # Shared traced execution logic for running a callable within a Langfuse
  # observe block, capturing output, trace_id, and any task error.
  #
  # Used by {DatasetItemClient#run} and {ExperimentRunner} to avoid duplicating
  # the observe/trace_id/begin-rescue/update pattern.
  #
  # @api private
  module TracedExecution
    # Execute a task proc within a traced observe block.
    #
    # @param trace_name [String] name for the observe span
    # @param input [Object] input set on the trace
    # @param metadata [Hash] metadata set on the trace
    # @param task [Proc] the callable to execute — receives the span
    # @yield [span, trace_id] optional pre-task hook (e.g., dataset run linking)
    # @return [Array(Object, String, String, StandardError, nil)] output, trace_id, observation_id, error
    def self.call(trace_name:, input:, task:, metadata: {})
      output = nil
      trace_id = nil
      observation_id = nil
      task_error = nil

      Langfuse.observe(trace_name) do |span|
        trace_id = span.trace_id
        observation_id = span.id
        span.update_trace(input: input, metadata: metadata)
        yield(span, trace_id) if block_given?
        begin
          output = task.call(span)
          span.update(output: output)
        rescue StandardError => e
          span.update(output: "Error: #{e.message}", level: "ERROR")
          task_error = e
        end
      end

      [output, trace_id, observation_id, task_error]
    end
  end
end
