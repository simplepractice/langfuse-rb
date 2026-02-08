# frozen_string_literal: true

RSpec.describe Langfuse::ExperimentItem do
  describe ".new" do
    it "creates an item with input and expected_output" do
      item = described_class.new(input: "question", expected_output: "answer")
      expect(item.input).to eq("question")
      expect(item.expected_output).to eq("answer")
    end

    it "allows nil expected_output" do
      item = described_class.new(input: "question", expected_output: nil)
      expect(item.expected_output).to be_nil
    end

    it "defaults metadata to nil" do
      item = described_class.new(input: "q", expected_output: "a")
      expect(item.metadata).to be_nil
    end

    it "accepts metadata" do
      item = described_class.new(input: "q", expected_output: "a", metadata: { key: "value" })
      expect(item.metadata).to eq({ key: "value" })
    end
  end

  describe "frozen value object" do
    it "is frozen" do
      item = described_class.new(input: "q", expected_output: "a")
      expect(item).to be_frozen
    end
  end

  describe "equality" do
    it "considers items with same attributes equal" do
      a = described_class.new(input: "q", expected_output: "a")
      b = described_class.new(input: "q", expected_output: "a")
      expect(a).to eq(b)
    end

    it "considers items with different attributes unequal" do
      a = described_class.new(input: "q1", expected_output: "a1")
      b = described_class.new(input: "q2", expected_output: "a2")
      expect(a).not_to eq(b)
    end

    it "considers items with different metadata unequal" do
      a = described_class.new(input: "q", expected_output: "a", metadata: { k: 1 })
      b = described_class.new(input: "q", expected_output: "a", metadata: { k: 2 })
      expect(a).not_to eq(b)
    end
  end
end
