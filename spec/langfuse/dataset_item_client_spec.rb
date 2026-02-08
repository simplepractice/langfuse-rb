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

    it "accepts optional client parameter" do
      mock_client = instance_double(Langfuse::Client)
      client = described_class.new(item_data, client: mock_client)
      expect(client).to be_a(described_class)
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

  describe "#link" do
    let(:mock_client) { instance_double(Langfuse::Client) }
    let(:item_client) { described_class.new(item_data, client: mock_client) }

    it "delegates to client.create_dataset_run_item" do
      expect(mock_client).to receive(:create_dataset_run_item).with(
        dataset_item_id: "item-123",
        run_name: "my-run",
        trace_id: "trace-abc",
        observation_id: nil,
        metadata: nil,
        run_description: nil
      )
      item_client.link(trace_id: "trace-abc", run_name: "my-run")
    end

    it "passes optional parameters" do
      expect(mock_client).to receive(:create_dataset_run_item).with(
        dataset_item_id: "item-123",
        run_name: "my-run",
        trace_id: "trace-abc",
        observation_id: "obs-def",
        metadata: { "k" => "v" },
        run_description: "a run"
      )
      item_client.link(
        trace_id: "trace-abc",
        run_name: "my-run",
        observation_id: "obs-def",
        metadata: { "k" => "v" },
        run_description: "a run"
      )
    end

    it "raises ArgumentError when no client" do
      item = described_class.new(item_data)
      expect { item.link(trace_id: "t", run_name: "r") }
        .to raise_error(ArgumentError, "client is required for this operation")
    end
  end

  describe "#run" do
    let(:mock_client) { instance_double(Langfuse::Client) }
    let(:item_client) { described_class.new(item_data, client: mock_client) }

    before do
      allow(mock_client).to receive(:create_dataset_run_item)
      allow(Langfuse).to receive(:force_flush)
    end

    it "raises ArgumentError when no block given" do
      expect { item_client.run(run_name: "test") }
        .to raise_error(ArgumentError, "block is required")
    end

    it "raises ArgumentError when no client" do
      item = described_class.new(item_data)
      expect { item.run(run_name: "test") { "output" } }
        .to raise_error(ArgumentError, "client is required for this operation")
    end

    it "yields a span to the block" do
      yielded_span = nil
      item_client.run(run_name: "test") do |span|
        yielded_span = span
        "output"
      end
      expect(yielded_span).to be_a(Langfuse::BaseObservation)
    end

    it "returns the block output" do
      result = item_client.run(run_name: "test") { "my-output" }
      expect(result).to eq("my-output")
    end

    it "links trace to dataset item" do
      expect(mock_client).to receive(:create_dataset_run_item).with(
        hash_including(
          dataset_item_id: "item-123",
          run_name: "test"
        )
      )
      item_client.run(run_name: "test") { "output" }
    end

    it "passes observation_id in link call" do
      expect(mock_client).to receive(:create_dataset_run_item).with(
        hash_including(
          observation_id: a_string_matching(/\A[0-9a-f]{16}\z/)
        )
      )
      item_client.run(run_name: "test") { "output" }
    end

    it "calls force_flush before linking" do
      call_order = []
      allow(Langfuse).to receive(:force_flush) { call_order << :flush }
      allow(mock_client).to receive(:create_dataset_run_item) { call_order << :link }
      item_client.run(run_name: "test") { "output" }
      expect(call_order).to eq(%i[flush link])
    end

    it "links trace and re-raises task errors after span ends" do
      expect(mock_client).to receive(:create_dataset_run_item).with(
        hash_including(
          dataset_item_id: "item-123",
          run_name: "test"
        )
      )

      expect do
        item_client.run(run_name: "test") { raise StandardError, "boom" }
      end.to raise_error(StandardError, "boom")
    end
  end
end
