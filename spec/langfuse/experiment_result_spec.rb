# frozen_string_literal: true

RSpec.describe Langfuse::ExperimentResult do
  let(:eval_accuracy) { Langfuse::Evaluation.new(name: "accuracy", value: 1.0) }
  let(:eval_relevance) { Langfuse::Evaluation.new(name: "relevance", value: 0.8) }

  let(:success_result) do
    Langfuse::ItemResult.new(
      item: Langfuse::ExperimentItem.new(input: "What is 2+2?", expected_output: "4"),
      output: "4",
      trace_id: "abc123",
      evaluations: [eval_accuracy, eval_relevance]
    )
  end

  let(:second_success_result) do
    Langfuse::ItemResult.new(
      item: Langfuse::ExperimentItem.new(input: "What is 3+3?", expected_output: "6"),
      output: "6",
      trace_id: "def456",
      evaluations: [
        Langfuse::Evaluation.new(name: "accuracy", value: 0.7),
        Langfuse::Evaluation.new(name: "relevance", value: 1.0)
      ]
    )
  end

  let(:failed_result) do
    Langfuse::ItemResult.new(
      item: Langfuse::ExperimentItem.new(input: "q2", expected_output: nil),
      error: StandardError.new("task failed"),
      trace_id: "err789"
    )
  end

  describe "#initialize" do
    it "creates an experiment result with defaults" do
      result = described_class.new(name: "test-exp", item_results: [success_result])
      expect(result.name).to eq("test-exp")
      expect(result.item_results.size).to eq(1)
      expect(result.run_evaluations).to eq([])
      expect(result.run_name).to be_nil
      expect(result.description).to be_nil
      expect(result.dataset_run_id).to be_nil
      expect(result.dataset_run_url).to be_nil
    end

    it "stores run_name and description" do
      result = described_class.new(
        name: "exp", item_results: [],
        run_name: "exp - 2025-01-01T00:00:00Z", description: "test desc"
      )
      expect(result.run_name).to eq("exp - 2025-01-01T00:00:00Z")
      expect(result.description).to eq("test desc")
    end

    it "stores dataset_run_id and dataset_run_url" do
      result = described_class.new(
        name: "exp", item_results: [],
        dataset_run_id: "run-123", dataset_run_url: "https://example.com/run/123"
      )
      expect(result.dataset_run_id).to eq("run-123")
      expect(result.dataset_run_url).to eq("https://example.com/run/123")
    end
  end

  describe "#successes" do
    it "returns only successful results" do
      result = described_class.new(name: "exp", item_results: [success_result, failed_result])
      expect(result.successes).to eq([success_result])
    end
  end

  describe "#failures" do
    it "returns only failed results" do
      result = described_class.new(name: "exp", item_results: [success_result, failed_result])
      expect(result.failures).to eq([failed_result])
    end
  end

  describe "#format" do
    context "with default (items hidden)" do
      it "shows hidden items hint" do
        result = described_class.new(name: "qa-v1", item_results: [success_result, second_success_result])
        output = result.format
        expect(output).to include("Individual Results: Hidden (2 items)")
        expect(output).to include("Set include_item_results: true to view them")
      end

      it "does not show per-item detail" do
        result = described_class.new(name: "qa-v1", item_results: [success_result])
        output = result.format
        expect(output).not_to include("Input:")
        expect(output).not_to include("Actual:")
      end
    end

    context "with include_item_results: true" do
      it "shows per-item input/expected/actual" do
        result = described_class.new(name: "qa-v1", item_results: [success_result])
        output = result.format(include_item_results: true)
        expect(output).to include("1. Item 1:")
        expect(output).to include("Input:    What is 2+2?")
        expect(output).to include("Expected: 4")
        expect(output).to include("Actual:   4")
      end

      it "shows per-item scores" do
        result = described_class.new(name: "exp", item_results: [success_result])
        output = result.format(include_item_results: true)
        expect(output).to include("Scores:")
        expect(output).to include("accuracy: 1.000")
        expect(output).to include("relevance: 0.800")
      end

      it "shows trace ID" do
        result = described_class.new(name: "exp", item_results: [success_result])
        output = result.format(include_item_results: true)
        expect(output).to include("Trace ID: abc123")
      end

      it "shows error for failed items" do
        result = described_class.new(name: "exp", item_results: [failed_result])
        output = result.format(include_item_results: true)
        expect(output).to include("Error: task failed")
        expect(output).to include("Trace ID: err789")
      end

      it "shows evaluation comments" do
        eval_with_comment = Langfuse::Evaluation.new(
          name: "accuracy", value: 1.0, comment: "Perfect match"
        )
        item = Langfuse::ItemResult.new(
          item: Langfuse::ExperimentItem.new(input: "q", expected_output: "a"),
          output: "a", trace_id: "t1", evaluations: [eval_with_comment]
        )
        result = described_class.new(name: "exp", item_results: [item])
        output = result.format(include_item_results: true)
        expect(output).to include("\u{1F4AD} Perfect match")
      end

      it "truncates long values at 50 chars" do
        long_input = "a" * 60
        item = Langfuse::ItemResult.new(
          item: Langfuse::ExperimentItem.new(input: long_input, expected_output: "short"),
          output: "short", trace_id: "t1"
        )
        result = described_class.new(name: "exp", item_results: [item])
        output = result.format(include_item_results: true)
        expect(output).to include("#{'a' * 47}...")
        expect(output).not_to include("a" * 60)
      end
    end

    context "with summary section" do
      it "shows experiment name with emoji" do
        result = described_class.new(name: "qa-v1", item_results: [success_result])
        expect(result.format).to include("\u{1F9EA} Experiment: qa-v1")
      end

      it "shows run_name when present" do
        result = described_class.new(
          name: "qa-v1", item_results: [success_result],
          run_name: "qa-v1 - 2025-01-01T00:00:00Z"
        )
        expect(result.format).to include("\u{1F4CB} Run name: qa-v1 - 2025-01-01T00:00:00Z")
      end

      it "shows description when present" do
        result = described_class.new(
          name: "qa-v1", item_results: [success_result], description: "Testing accuracy"
        )
        expect(result.format).to include("\u{1F4DD} Description: Testing accuracy")
      end

      it "shows dataset_run_url when present" do
        result = described_class.new(
          name: "qa-v1", item_results: [success_result],
          dataset_run_url: "https://langfuse.com/runs/123"
        )
        expect(result.format).to include("\u{1F517} Dataset run: https://langfuse.com/runs/123")
      end

      it "omits dataset_run_url when nil" do
        result = described_class.new(name: "qa-v1", item_results: [success_result])
        expect(result.format).not_to include("Dataset run:")
      end

      it "omits run_name and description when nil" do
        result = described_class.new(name: "qa-v1", item_results: [success_result])
        output = result.format
        expect(output).not_to include("Run name:")
        expect(output).not_to include("Description:")
      end

      it "shows item count" do
        result = described_class.new(name: "exp", item_results: [success_result, second_success_result])
        expect(result.format).to include("2 items")
      end
    end

    context "with evaluation names" do
      it "lists unique evaluation names" do
        result = described_class.new(
          name: "exp", item_results: [success_result, second_success_result]
        )
        output = result.format
        expect(output).to include("Evaluations:")
        expect(output).to include("\u2022 accuracy")
        expect(output).to include("\u2022 relevance")
      end

      it "omits evaluations section when no evaluations exist" do
        plain_item = Langfuse::ExperimentItem.new(input: "q", expected_output: nil)
        plain = Langfuse::ItemResult.new(item: plain_item, output: "a")
        result = described_class.new(name: "exp", item_results: [plain])
        expect(result.format).not_to include("Evaluations:")
      end
    end

    context "with average scores" do
      it "computes averages across items" do
        result = described_class.new(
          name: "exp", item_results: [success_result, second_success_result]
        )
        output = result.format
        expect(output).to include("Average Scores:")
        expect(output).to include("accuracy: 0.850")
        expect(output).to include("relevance: 0.900")
      end

      it "omits average scores when no numeric evaluations" do
        plain_item = Langfuse::ExperimentItem.new(input: "q", expected_output: nil)
        plain = Langfuse::ItemResult.new(item: plain_item, output: "a")
        result = described_class.new(name: "exp", item_results: [plain])
        expect(result.format).not_to include("Average Scores:")
      end
    end

    context "with run evaluations" do
      it "shows run evaluations with formatted scores" do
        run_eval = Langfuse::Evaluation.new(name: "avg_accuracy", value: 0.85)
        result = described_class.new(
          name: "exp", item_results: [success_result], run_evaluations: [run_eval]
        )
        output = result.format
        expect(output).to include("Run Evaluations:")
        expect(output).to include("avg_accuracy: 0.850")
      end

      it "shows comments on run evaluations" do
        run_eval = Langfuse::Evaluation.new(
          name: "avg_accuracy", value: 0.85, comment: "Average accuracy: 85.00%"
        )
        result = described_class.new(
          name: "exp", item_results: [success_result], run_evaluations: [run_eval]
        )
        output = result.format
        expect(output).to include("\u{1F4AD} Average accuracy: 85.00%")
      end

      it "omits run evaluations section when empty" do
        result = described_class.new(name: "exp", item_results: [success_result])
        expect(result.format).not_to include("Run Evaluations:")
      end
    end

    context "with separator" do
      it "uses thin box-drawing separator" do
        result = described_class.new(name: "exp", item_results: [success_result])
        expect(result.format).to include("\u2500" * 50)
      end
    end
  end
end
