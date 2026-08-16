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
    # @param input [Object] input set on the root observation
    # @param metadata [Hash] metadata set on the root observation and trace
    # @param task [Proc] the callable to execute — receives the span
    # @yield [span, trace_id] optional pre-task hook (e.g., dataset run linking)
    # @return [Array<(Object, String, String, StandardError | nil)>] output, trace_id, observation_id, error
    def self.call(trace_name:, input:, task:, metadata: {})
      trace_id = nil
      observation_id = nil
      output = nil
      task_error = nil

      Langfuse.observe(trace_name, input: input, metadata: metadata) do |span|
        trace_id = span.trace_id
        observation_id = span.id
        Langfuse.propagate_attributes(trace_name: trace_name, metadata: metadata) do
          yield(span, trace_id) if block_given?
          output, task_error = execute_task(span, task)
        end
      end

      [output, trace_id, observation_id, task_error]
    end

    # @api private
    def self.execute_task(span, task)
      output = task.call(span)
      span.update(output: output)
      [output, nil]
    rescue StandardError => e
      span.update(output: "Error: #{e.message}", level: "ERROR")
      [nil, e]
    end
    private_class_method :execute_task
  end
end
