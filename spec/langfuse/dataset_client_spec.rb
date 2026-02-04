# frozen_string_literal: true

RSpec.describe Langfuse::DatasetClient do
  let(:dataset_data) do
    {
      "id" => "dataset-123",
      "name" => "evaluation-qa",
      "description" => "QA evaluation dataset",
      "metadata" => { "version" => "1.0" },
      "createdAt" => "2024-01-15T10:30:00Z",
      "updatedAt" => "2024-01-16T14:45:00Z",
      "items" => []
    }
  end

  describe "#initialize" do
    it "creates a dataset client" do
      client = described_class.new(dataset_data)
      expect(client).to be_a(described_class)
    end

    it "sets the id" do
      client = described_class.new(dataset_data)
      expect(client.id).to eq("dataset-123")
    end

    it "sets the name" do
      client = described_class.new(dataset_data)
      expect(client.name).to eq("evaluation-qa")
    end

    it "sets the description" do
      client = described_class.new(dataset_data)
      expect(client.description).to eq("QA evaluation dataset")
    end

    it "sets the metadata" do
      client = described_class.new(dataset_data)
      expect(client.metadata).to eq({ "version" => "1.0" })
    end

    it "parses created_at timestamp" do
      client = described_class.new(dataset_data)
      expect(client.created_at).to be_a(Time)
      expect(client.created_at.year).to eq(2024)
    end

    it "parses updated_at timestamp" do
      client = described_class.new(dataset_data)
      expect(client.updated_at).to be_a(Time)
      expect(client.updated_at.month).to eq(1)
    end

    it "defaults metadata to empty hash when not provided" do
      data = dataset_data.dup.tap { |d| d.delete("metadata") }
      client = described_class.new(data)
      expect(client.metadata).to eq({})
    end

    it "handles nil timestamps" do
      data = dataset_data.merge("createdAt" => nil, "updatedAt" => nil)
      client = described_class.new(data)
      expect(client.created_at).to be_nil
      expect(client.updated_at).to be_nil
    end

    it "handles invalid timestamp format gracefully" do
      data = dataset_data.merge("createdAt" => "invalid-timestamp")
      client = described_class.new(data)
      expect(client.created_at).to eq("invalid-timestamp")
    end

    context "with invalid dataset data" do
      it "raises ArgumentError when dataset_data is not a Hash" do
        expect { described_class.new("not a hash") }.to raise_error(
          ArgumentError, "dataset_data must be a Hash"
        )
      end

      it "raises ArgumentError when id field is missing" do
        data = dataset_data.dup.tap { |d| d.delete("id") }
        expect { described_class.new(data) }.to raise_error(
          ArgumentError, "dataset_data must include 'id' field"
        )
      end

      it "raises ArgumentError when name field is missing" do
        data = dataset_data.dup.tap { |d| d.delete("name") }
        expect { described_class.new(data) }.to raise_error(
          ArgumentError, "dataset_data must include 'name' field"
        )
      end
    end
  end

  describe "#items" do
    context "with no items" do
      it "returns empty array" do
        client = described_class.new(dataset_data)
        expect(client.items).to eq([])
      end
    end

    context "with items" do
      let(:dataset_with_items) do
        dataset_data.merge(
          "items" => [
            { "id" => "item-1", "datasetId" => "dataset-123", "input" => { "q" => "test" } },
            { "id" => "item-2", "datasetId" => "dataset-123", "input" => { "q" => "test2" } }
          ]
        )
      end

      it "returns array of DatasetItemClient instances" do
        client = described_class.new(dataset_with_items)
        expect(client.items).to all(be_a(Langfuse::DatasetItemClient))
      end

      it "returns correct number of items" do
        client = described_class.new(dataset_with_items)
        expect(client.items.size).to eq(2)
      end

      it "wraps items with correct data" do
        client = described_class.new(dataset_with_items)
        expect(client.items.first.id).to eq("item-1")
        expect(client.items.last.id).to eq("item-2")
      end

      it "memoizes items" do
        client = described_class.new(dataset_with_items)
        items1 = client.items
        items2 = client.items
        expect(items1).to equal(items2)
      end
    end
  end
end
