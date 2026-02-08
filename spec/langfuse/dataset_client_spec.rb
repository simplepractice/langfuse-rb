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

    it "accepts optional client parameter" do
      mock_client = instance_double(Langfuse::Client)
      client = described_class.new(dataset_data, client: mock_client)
      expect(client).to be_a(described_class)
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

  describe "#url" do
    context "without client" do
      it "returns nil" do
        client = described_class.new(dataset_data)
        expect(client.url).to be_nil
      end
    end

    context "with client" do
      let(:mock_client) { instance_double(Langfuse::Client) }

      it "delegates to client.dataset_url with id" do
        allow(mock_client).to receive(:dataset_url)
          .with("dataset-123")
          .and_return("https://cloud.langfuse.com/project/proj-abc/datasets/dataset-123")

        client = described_class.new(dataset_data, client: mock_client)
        expect(client.url).to eq("https://cloud.langfuse.com/project/proj-abc/datasets/dataset-123")
      end
    end
  end

  describe "#items" do
    context "with no items and no client" do
      it "returns empty array" do
        client = described_class.new(dataset_data)
        expect(client.items).to eq([])
      end
    end

    context "with no embedded items but client available" do
      let(:mock_client) { instance_double(Langfuse::Client) }
      let(:fetched_items) do
        [
          instance_double(Langfuse::DatasetItemClient, id: "item-1"),
          instance_double(Langfuse::DatasetItemClient, id: "item-2")
        ]
      end

      it "fetches items via client.list_dataset_items" do
        allow(mock_client).to receive(:list_dataset_items)
          .with(dataset_name: "evaluation-qa")
          .and_return(fetched_items)

        client = described_class.new(dataset_data, client: mock_client)
        expect(client.items).to eq(fetched_items)
        expect(mock_client).to have_received(:list_dataset_items).with(dataset_name: "evaluation-qa")
      end

      it "memoizes the fetched items" do
        allow(mock_client).to receive(:list_dataset_items).and_return(fetched_items)
        client = described_class.new(dataset_data, client: mock_client)

        items1 = client.items
        items2 = client.items
        expect(items1).to equal(items2)
        expect(mock_client).to have_received(:list_dataset_items).once
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

      it "passes client to DatasetItemClient instances" do
        mock_client = instance_double(Langfuse::Client)
        allow(mock_client).to receive(:create_dataset_run_item)
        client = described_class.new(dataset_with_items, client: mock_client)
        # Items should be constructed with client (verified by link not raising)
        item = client.items.first
        expect { item.link(trace_id: "t", run_name: "r") }.not_to raise_error
      end
    end
  end

  describe "#run_experiment" do
    let(:mock_client) { instance_double(Langfuse::Client) }
    let(:dataset_with_items) do
      dataset_data.merge(
        "items" => [
          { "id" => "item-1", "datasetId" => "dataset-123", "input" => { "q" => "test" } }
        ]
      )
    end

    it "raises ArgumentError without client" do
      client = described_class.new(dataset_with_items)
      expect do
        client.run_experiment(name: "test", task: ->(_item) { "output" })
      end.to raise_error(ArgumentError, "client is required for this operation")
    end

    context "when dataset has no embedded items" do
      it "fetches items via client before delegating to client.run_experiment" do
        fetched_items = [
          instance_double(Langfuse::DatasetItemClient, id: "item-1")
        ]
        allow(mock_client).to receive(:list_dataset_items)
          .with(dataset_name: "evaluation-qa")
          .and_return(fetched_items)

        mock_result = instance_double(Langfuse::ExperimentResult)
        allow(mock_client).to receive(:run_experiment).and_return(mock_result)

        client = described_class.new(dataset_data, client: mock_client)
        client.run_experiment(name: "test-exp", task: ->(_item) { "output" })

        expect(mock_client).to have_received(:list_dataset_items).with(dataset_name: "evaluation-qa")
        expect(mock_client).to have_received(:run_experiment).with(
          hash_including(data: fetched_items)
        )
      end
    end

    it "delegates to client.run_experiment" do
      mock_result = instance_double(Langfuse::ExperimentResult)
      allow(mock_client).to receive(:run_experiment).and_return(mock_result)

      client = described_class.new(dataset_with_items, client: mock_client)
      task = ->(_item) { "output" }

      result = client.run_experiment(name: "test-exp", task: task)
      expect(result).to eq(mock_result)
      expect(mock_client).to have_received(:run_experiment).with(
        hash_including(
          name: "test-exp",
          task: task
        )
      )
    end
  end
end
