# frozen_string_literal: true

require "digest"

RSpec.describe Langfuse::ExperimentAttributes do
  describe ".generate_experiment_id" do
    it "returns unique 16-character hexadecimal identifiers" do
      first_id = described_class.generate_experiment_id
      second_id = described_class.generate_experiment_id

      expect(first_id).to match(/\A[0-9a-f]{16}\z/)
      expect(second_id).to match(/\A[0-9a-f]{16}\z/)
      expect(second_id).not_to eq(first_id)
    end
  end

  describe ".generate_item_id" do
    it "hashes the SDK-serialized input deterministically" do
      input = { question: "What is 2 + 2?" }
      serialized = Langfuse::OtelAttributes.serialize(input, preserve_strings: true)
      expected_id = Digest::SHA256.hexdigest(serialized)[0, 16]

      expect(described_class.generate_item_id(input)).to eq(expected_id)
      expect(described_class.generate_item_id(input)).to eq(expected_id)
    end

    it "falls back to the input string when serialization fails" do
      input = Object.new
      allow(input).to receive(:to_json).and_raise(StandardError, "cannot serialize")
      allow(input).to receive(:to_s).and_return("stable input")

      expected_id = Digest::SHA256.hexdigest("stable input")[0, 16]
      expect(described_class.generate_item_id(input)).to eq(expected_id)
    end
  end

  describe ".propagated" do
    it "builds v4 identity, dataset, metadata, and environment attributes" do
      attributes = described_class.propagated(
        experiment_id: "run-id", run_name: "nightly",
        dataset_id: "dataset-id", item_id: "item-id", root_observation_id: "observation-id",
        experiment_metadata: { model: { name: "test" } }, item_metadata: { difficulty: "easy" }
      )

      expect(attributes).to include(
        "langfuse.experiment.id" => "run-id",
        "langfuse.experiment.name" => "nightly",
        "langfuse.experiment.dataset.id" => "dataset-id",
        "langfuse.experiment.item.id" => "item-id",
        "langfuse.experiment.item.root_observation_id" => "observation-id",
        "langfuse.experiment.metadata.model.name" => "test",
        "langfuse.experiment.item.metadata.difficulty" => "easy",
        "langfuse.environment" => "sdk-experiment"
      )
    end

    it "applies masking before flattening experiment and item metadata" do
      mask = lambda do |data:|
        data.transform_values { |value| value == "secret" ? "redacted" : value }
      end

      attributes = described_class.propagated(
        experiment_id: "run-id", run_name: "nightly", item_id: "item-id",
        root_observation_id: "observation-id", experiment_metadata: { token: "secret" },
        item_metadata: { answer: "secret" }, mask: mask
      )

      expect(attributes["langfuse.experiment.metadata.token"]).to eq("redacted")
      expect(attributes["langfuse.experiment.item.metadata.answer"]).to eq("redacted")
    end
  end

  describe ".root" do
    it "keeps description and false expected output on the item root" do
      attributes = described_class.root(description: "test run", expected_output: false)

      expect(attributes).to eq(
        "langfuse.experiment.description" => "test run",
        "langfuse.experiment.item.expected_output" => "false"
      )
    end

    it "omits nil expected output" do
      attributes = described_class.root(description: nil, expected_output: nil)

      expect(attributes).to eq({})
    end

    it "masks expected output before serialization" do
      mask = ->(data:) { data == "secret" ? "redacted" : data }

      attributes = described_class.root(description: nil, expected_output: "secret", mask: mask)

      expect(attributes["langfuse.experiment.item.expected_output"]).to eq("redacted")
    end
  end

  describe ".observation_metadata" do
    it "merges item metadata before run metadata and adds fixed experiment fields" do
      metadata = described_class.observation_metadata(
        name: "quality", run_name: "nightly",
        item_metadata: { shared: "item", item_only: true },
        experiment_metadata: { shared: "run", run_only: true },
        dataset_id: "dataset-id", dataset_item_id: "item-id"
      )

      expect(metadata).to include(
        shared: "run", item_only: true, run_only: true,
        experiment_name: "quality", experiment_run_name: "nightly",
        dataset_id: "dataset-id", dataset_item_id: "item-id"
      )
    end
  end
end
