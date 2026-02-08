# frozen_string_literal: true

RSpec.describe Langfuse::ItemResult do
  let(:item) { { input: "test" } }

  describe "#initialize" do
    it "creates a result with minimal params" do
      result = described_class.new(item: item)
      expect(result.item).to eq(item)
      expect(result.output).to be_nil
      expect(result.trace_id).to be_nil
      expect(result.observation_id).to be_nil
      expect(result.evaluations).to eq([])
      expect(result.error).to be_nil
    end

    it "creates a result with all params" do
      eval = Langfuse::Evaluation.new(name: "score", value: 1.0)
      result = described_class.new(
        item: item,
        output: "answer",
        trace_id: "trace-123",
        observation_id: "obs-456",
        evaluations: [eval],
        error: nil
      )
      expect(result.output).to eq("answer")
      expect(result.trace_id).to eq("trace-123")
      expect(result.observation_id).to eq("obs-456")
      expect(result.evaluations).to eq([eval])
    end
  end

  describe "#success?" do
    it "returns true when no error" do
      result = described_class.new(item: item, output: "answer")
      expect(result.success?).to be true
    end

    it "returns false when error present" do
      result = described_class.new(item: item, error: StandardError.new("boom"))
      expect(result.success?).to be false
    end
  end

  describe "#failed?" do
    it "returns true when error present" do
      result = described_class.new(item: item, error: StandardError.new("boom"))
      expect(result.failed?).to be true
    end

    it "returns false when no error" do
      result = described_class.new(item: item, output: "answer")
      expect(result.failed?).to be false
    end
  end
end
