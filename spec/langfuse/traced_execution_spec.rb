# frozen_string_literal: true

RSpec.describe Langfuse::TracedExecution do
  before do
    allow(Langfuse).to receive(:force_flush)
  end

  describe ".call" do
    it "returns output, trace_id, observation_id, and nil error on success" do
      output, trace_id, observation_id, error = described_class.call(
        trace_name: "test-trace",
        input: { q: "hello" },
        task: ->(_span) { "result" }
      )

      expect(output).to eq("result")
      expect(trace_id).to be_a(String)
      expect(trace_id.length).to eq(32)
      expect(observation_id).to be_a(String)
      expect(observation_id.length).to eq(16)
      expect(error).to be_nil
    end

    it "captures task errors without re-raising" do
      output, trace_id, observation_id, error = described_class.call(
        trace_name: "test-trace",
        input: {},
        task: ->(_span) { raise StandardError, "boom" }
      )

      expect(output).to be_nil
      expect(trace_id).to be_a(String)
      expect(observation_id).to be_a(String)
      expect(error).to be_a(StandardError)
      expect(error.message).to eq("boom")
    end

    it "marks the span with error state on task failure" do
      span_captured = nil
      described_class.call(
        trace_name: "test-trace",
        input: {},
        task: lambda { |span|
          span_captured = span
          raise StandardError, "boom"
        }
      )

      expect(span_captured).to be_a(Langfuse::BaseObservation)
    end

    it "passes the span to the task" do
      received_span = nil
      described_class.call(
        trace_name: "test-trace",
        input: {},
        task: ->(span) { received_span = span }
      )

      expect(received_span).to be_a(Langfuse::BaseObservation)
    end

    it "sets input and metadata on the trace" do
      span_captured = nil
      described_class.call(
        trace_name: "test-trace",
        input: { question: "What?" },
        metadata: { run: "v1" },
        task: ->(span) { span_captured = span }
      )

      expect(span_captured).to be_a(Langfuse::BaseObservation)
    end

    it "defaults metadata to empty hash" do
      # Should not raise when metadata is omitted
      output, _trace_id, _observation_id, error = described_class.call(
        trace_name: "test-trace",
        input: {},
        task: ->(_span) { "ok" }
      )

      expect(output).to eq("ok")
      expect(error).to be_nil
    end

    it "yields span and trace_id to the pre-task hook" do
      yielded_span = nil
      yielded_trace_id = nil

      described_class.call(
        trace_name: "test-trace",
        input: {},
        task: ->(_span) { "result" }
      ) do |span, trace_id|
        yielded_span = span
        yielded_trace_id = trace_id
      end

      expect(yielded_span).to be_a(Langfuse::BaseObservation)
      expect(yielded_trace_id).to be_a(String)
      expect(yielded_trace_id.length).to eq(32)
    end

    it "executes the pre-task hook before the task" do
      call_order = []

      described_class.call(
        trace_name: "test-trace",
        input: {},
        task: lambda { |_span|
          call_order << :task
          "result"
        }
      ) do |_span, _trace_id|
        call_order << :hook
      end

      expect(call_order).to eq(%i[hook task])
    end

    it "still captures task error when pre-task hook is given" do
      _output, _trace_id, _observation_id, error = described_class.call(
        trace_name: "test-trace",
        input: {},
        task: ->(_span) { raise StandardError, "task failed" }
      ) { |_span, _trace_id| }

      expect(error).to be_a(StandardError)
      expect(error.message).to eq("task failed")
    end
  end
end
