# frozen_string_literal: true

RSpec.describe Langfuse::DatasetItemClient do
  let(:item_data) do
    {
      "id" => "item-123",
      "datasetId" => "dataset-456",
      "input" => { "question" => "What is 2+2?" },
      "expectedOutput" => { "answer" => "4" },
      "metadata" => { "difficulty" => "easy" },
      "sourceTraceId" => "trace-789",
      "sourceObservationId" => "obs-012",
      "status" => "ACTIVE",
      "createdAt" => "2024-01-15T10:30:00Z",
      "updatedAt" => "2024-01-16T14:45:00Z"
    }
  end

  describe "#initialize" do
    it "creates a dataset item client" do
      client = described_class.new(item_data)
      expect(client).to be_a(described_class)
    end

    it "sets the id" do
      client = described_class.new(item_data)
      expect(client.id).to eq("item-123")
    end

    it "sets the dataset_id" do
      client = described_class.new(item_data)
      expect(client.dataset_id).to eq("dataset-456")
    end

    it "sets the input" do
      client = described_class.new(item_data)
      expect(client.input).to eq({ "question" => "What is 2+2?" })
    end

    it "sets the expected_output" do
      client = described_class.new(item_data)
      expect(client.expected_output).to eq({ "answer" => "4" })
    end

    it "sets the metadata" do
      client = described_class.new(item_data)
      expect(client.metadata).to eq({ "difficulty" => "easy" })
    end

    it "sets the source_trace_id" do
      client = described_class.new(item_data)
      expect(client.source_trace_id).to eq("trace-789")
    end

    it "sets the source_observation_id" do
      client = described_class.new(item_data)
      expect(client.source_observation_id).to eq("obs-012")
    end

    it "sets the status" do
      client = described_class.new(item_data)
      expect(client.status).to eq("ACTIVE")
    end

    it "parses created_at timestamp" do
      client = described_class.new(item_data)
      expect(client.created_at).to be_a(Time)
      expect(client.created_at.year).to eq(2024)
    end

    it "parses updated_at timestamp" do
      client = described_class.new(item_data)
      expect(client.updated_at).to be_a(Time)
    end

    it "defaults metadata to empty hash when not provided" do
      data = item_data.dup.tap { |d| d.delete("metadata") }
      client = described_class.new(data)
      expect(client.metadata).to eq({})
    end

    it "defaults status to ACTIVE when not provided" do
      data = item_data.dup.tap { |d| d.delete("status") }
      client = described_class.new(data)
      expect(client.status).to eq("ACTIVE")
    end

    it "handles nil timestamps" do
      data = item_data.merge("createdAt" => nil, "updatedAt" => nil)
      client = described_class.new(data)
      expect(client.created_at).to be_nil
      expect(client.updated_at).to be_nil
    end

    it "handles nil source IDs" do
      data = item_data.merge("sourceTraceId" => nil, "sourceObservationId" => nil)
      client = described_class.new(data)
      expect(client.source_trace_id).to be_nil
      expect(client.source_observation_id).to be_nil
    end

    it "handles invalid timestamp format gracefully" do
      data = item_data.merge("createdAt" => "invalid-timestamp")
      client = described_class.new(data)
      expect(client.created_at).to eq("invalid-timestamp")
    end

    context "with invalid item data" do
      it "raises ArgumentError when item_data is not a Hash" do
        expect { described_class.new("not a hash") }.to raise_error(
          ArgumentError, "item_data must be a Hash"
        )
      end

      it "raises ArgumentError when id field is missing" do
        data = item_data.dup.tap { |d| d.delete("id") }
        expect { described_class.new(data) }.to raise_error(
          ArgumentError, "item_data must include 'id' field"
        )
      end
    end
  end

  describe "#active?" do
    it "returns true when status is ACTIVE" do
      client = described_class.new(item_data)
      expect(client.active?).to be true
    end

    it "returns false when status is ARCHIVED" do
      data = item_data.merge("status" => "ARCHIVED")
      client = described_class.new(data)
      expect(client.active?).to be false
    end
  end

  describe "#archived?" do
    it "returns true when status is ARCHIVED" do
      data = item_data.merge("status" => "ARCHIVED")
      client = described_class.new(data)
      expect(client.archived?).to be true
    end

    it "returns false when status is ACTIVE" do
      client = described_class.new(item_data)
      expect(client.archived?).to be false
    end
  end
end
