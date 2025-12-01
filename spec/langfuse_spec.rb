# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"

RSpec.describe Langfuse do
  before do
    described_class.reset!
    # Setup minimal OTel for testing
    tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    OpenTelemetry.tracer_provider = tracer_provider
  end

  it "has a version number" do
    expect(Langfuse::VERSION).not_to be_nil
  end

  describe ".configuration" do
    it "returns a Config instance" do
      expect(described_class.configuration).to be_a(Langfuse::Config)
    end

    it "memoizes the configuration" do
      config1 = described_class.configuration
      config2 = described_class.configuration
      expect(config1).to eq(config2)
    end
  end

  describe ".configure" do
    it "yields configuration" do
      expect { |b| described_class.configure(&b) }.to yield_with_args(Langfuse::Config)
    end

    it "allows setting configuration values" do
      described_class.configure do |config|
        config.public_key = "test_pk"
        config.secret_key = "test_sk"
        config.cache_ttl = 300
      end

      expect(described_class.configuration.public_key).to eq("test_pk")
      expect(described_class.configuration.secret_key).to eq("test_sk")
      expect(described_class.configuration.cache_ttl).to eq(300)
    end
  end

  describe ".client" do
    before do
      described_class.configure do |config|
        config.public_key = "pk_test_123"
        config.secret_key = "sk_test_456"
        config.base_url = "https://cloud.langfuse.com"
      end
    end

    it "returns a Client instance" do
      expect(described_class.client).to be_a(Langfuse::Client)
    end

    it "memoizes the client" do
      client1 = described_class.client
      client2 = described_class.client
      expect(client1).to eq(client2)
    end

    it "uses the global configuration" do
      client = described_class.client
      expect(client.config).to eq(described_class.configuration)
    end

    it "creates client with configured settings" do
      client = described_class.client
      expect(client.api_client.public_key).to eq("pk_test_123")
      expect(client.api_client.secret_key).to eq("sk_test_456")
      expect(client.api_client.base_url).to eq("https://cloud.langfuse.com")
    end
  end

  describe ".reset!" do
    it "resets configuration and client" do
      described_class.configure { |c| c.public_key = "test" }
      described_class.reset!

      expect(described_class.instance_variable_get(:@configuration)).to be_nil
      expect(described_class.instance_variable_get(:@client)).to be_nil
    end

    it "allows creating new configuration after reset" do
      described_class.configure { |c| c.public_key = "old_key" }
      described_class.reset!

      described_class.configure { |c| c.public_key = "new_key" }
      expect(described_class.configuration.public_key).to eq("new_key")
    end

    it "sets instance variables to nil" do
      described_class.configure do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
        c.base_url = "https://cloud.langfuse.com"
      end
      # Create a client to set @client
      _client = described_class.client

      # Verify they're set before reset
      expect(described_class.instance_variable_get(:@configuration)).not_to be_nil
      expect(described_class.instance_variable_get(:@client)).not_to be_nil

      described_class.reset!

      expect(described_class.instance_variable_get(:@configuration)).to be_nil
      expect(described_class.instance_variable_get(:@client)).to be_nil
    end
  end

  describe ".shutdown" do
    before do
      described_class.configure do |config|
        config.public_key = "pk_test"
        config.secret_key = "sk_test"
        config.base_url = "https://cloud.langfuse.com"
      end
    end

    it "calls OtelSetup.shutdown with timeout" do
      expect(Langfuse::OtelSetup).to receive(:shutdown).with(timeout: 30)
      described_class.shutdown
    end

    it "accepts custom timeout" do
      expect(Langfuse::OtelSetup).to receive(:shutdown).with(timeout: 10)
      described_class.shutdown(timeout: 10)
    end
  end

  describe ".propagate_attributes" do
    before do
      described_class.configure do |config|
        config.public_key = "pk_test"
        config.secret_key = "sk_test"
        config.base_url = "https://cloud.langfuse.com"
      end
    end

    it "delegates to Propagation.propagate_attributes" do
      expect(Langfuse::Propagation).to receive(:propagate_attributes).with(
        user_id: "user_123",
        session_id: nil,
        metadata: nil,
        version: nil,
        tags: nil,
        as_baggage: false
      ).and_call_original

      described_class.propagate_attributes(user_id: "user_123") do
        # Block should execute
      end
    end

    it "passes all parameters to Propagation" do
      expect(Langfuse::Propagation).to receive(:propagate_attributes).with(
        user_id: "user_123",
        session_id: "session_abc",
        metadata: { env: "test" },
        version: "v1.0",
        tags: ["tag1"],
        as_baggage: true
      ).and_call_original

      described_class.propagate_attributes(
        user_id: "user_123",
        session_id: "session_abc",
        metadata: { env: "test" },
        version: "v1.0",
        tags: ["tag1"],
        as_baggage: true
      ) do
        # Block should execute
      end
    end
  end

  describe ".start_observation" do
    it "creates a root span observation" do
      observation = described_class.start_observation("test-span", { input: { data: "test" } })
      expect(observation).to be_a(Langfuse::Span)
      expect(observation.type).to eq("span")
    end

    it "creates a root generation observation" do
      observation = described_class.start_observation("test-gen", { model: "gpt-4" }, as_type: :generation)
      expect(observation).to be_a(Langfuse::Generation)
      expect(observation.type).to eq("generation")
    end

    it "creates a root event observation" do
      observation = described_class.start_observation("test-event", {}, as_type: :event)
      expect(observation).to be_a(Langfuse::Event)
      expect(observation.type).to eq("event")
      # Events should be auto-ended
      expect(observation.otel_span.recording?).to be(false)
    end

    it "creates a root agent observation" do
      observation = described_class.start_observation("test-agent", { input: { task: "test" } }, as_type: :agent)
      expect(observation).to be_a(Langfuse::Agent)
      expect(observation.type).to eq("agent")
    end

    it "creates a root tool observation" do
      observation = described_class.start_observation("test-tool", { input: { query: "test" } }, as_type: :tool)
      expect(observation).to be_a(Langfuse::Tool)
      expect(observation.type).to eq("tool")
    end

    it "creates a root chain observation" do
      observation = described_class.start_observation("test-chain", { input: { query: "test" } }, as_type: :chain)
      expect(observation).to be_a(Langfuse::Chain)
      expect(observation.type).to eq("chain")
    end

    it "creates a root retriever observation" do
      observation = described_class.start_observation("test-retriever", { input: { query: "test" } },
                                                      as_type: :retriever)
      expect(observation).to be_a(Langfuse::Retriever)
      expect(observation.type).to eq("retriever")
    end

    it "creates a root evaluator observation" do
      observation = described_class.start_observation("test-evaluator", { input: { response: "test" } },
                                                      as_type: :evaluator)
      expect(observation).to be_a(Langfuse::Evaluator)
      expect(observation.type).to eq("evaluator")
    end

    it "creates a root guardrail observation" do
      observation = described_class.start_observation("test-guardrail", { input: { content: "test" } },
                                                      as_type: :guardrail)
      expect(observation).to be_a(Langfuse::Guardrail)
      expect(observation.type).to eq("guardrail")
    end

    it "creates a root embedding observation" do
      attrs = { input: { texts: ["test"] }, model: "text-embedding-ada-002" }
      observation = described_class.start_observation("test-embedding", attrs, as_type: :embedding)
      expect(observation).to be_a(Langfuse::Embedding)
      expect(observation.type).to eq("embedding")
    end

    it "creates a child observation with parent context" do
      parent = described_class.start_observation("parent", {})
      child = described_class.start_observation(
        "child",
        {},
        parent_span_context: parent.otel_span.context
      )

      expect(child).to be_a(Langfuse::Span)
      expect(child.trace_id).to eq(parent.trace_id)
      expect(child.otel_span.to_span_data.parent_span_id).to eq(parent.otel_span.context.span_id)
    end

    it "sets attributes on the observation" do
      observation = described_class.start_observation("test", {
                                                        input: { query: "test" },
                                                        output: { result: "success" },
                                                        metadata: { source: "api" }
                                                      })

      span_data = observation.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "query" => "test" })
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "result" => "success" })
      expect(span_data.attributes["langfuse.observation.metadata.source"]).to eq("api")
    end

    context "with invalid observation types" do
      it "raises ArgumentError for invalid symbol type" do
        expect do
          described_class.start_observation("test", {}, as_type: :invalid)
        end.to raise_error(ArgumentError, /Invalid observation type: invalid/)
      end

      it "raises ArgumentError for invalid string type" do
        expect do
          described_class.start_observation("test", {}, as_type: "invalid")
        end.to raise_error(ArgumentError, /Invalid observation type: invalid/)
      end

      it "includes valid types in error message" do
        expect do
          described_class.start_observation("test", {}, as_type: :invalid)
        end.to raise_error(ArgumentError, /Valid types: .*span/)
      end

      it "raises ArgumentError for nil type" do
        expect do
          described_class.start_observation("test", {}, as_type: nil)
        end.to raise_error(ArgumentError, /Invalid observation type/)
      end

      it "accepts valid symbol types" do
        expect do
          described_class.start_observation("test", {}, as_type: :span)
          described_class.start_observation("test", {}, as_type: :generation)
          described_class.start_observation("test", {}, as_type: :event)
        end.not_to raise_error
      end

      it "accepts valid string types" do
        expect do
          described_class.start_observation("test", {}, as_type: "span")
          described_class.start_observation("test", {}, as_type: "generation")
          described_class.start_observation("test", {}, as_type: "event")
        end.not_to raise_error
      end
    end
  end

  describe ".observe" do
    it "creates and returns observation without block" do
      observation = described_class.observe("test", input: { data: "test" })
      expect(observation).to be_a(Langfuse::Span)
      expect(observation.otel_span.recording?).to be(true) # Not ended yet
    end

    it "auto-ends observation with block" do
      result = described_class.observe("test") do |obs|
        obs.update(input: { data: "test" })
        "block_result"
      end

      expect(result).to eq("block_result")
      # Observation should be ended
      # We can't directly check if the observation was ended, but the block should have executed
    end

    it "auto-ends events even without block" do
      observation = described_class.observe("test-event", {}, as_type: :event)
      expect(observation).to be_a(Langfuse::Event)
      expect(observation.otel_span.recording?).to be(false) # Auto-ended
    end

    it "supports different observation types" do
      span = described_class.observe("span-test", {}, as_type: :span)
      gen = described_class.observe("gen-test", { model: "gpt-4" }, as_type: :generation)
      event = described_class.observe("event-test", {}, as_type: :event)
      agent = described_class.observe("agent-test", { input: { task: "test" } }, as_type: :agent)
      tool = described_class.observe("tool-test", { input: { query: "test" } }, as_type: :tool)
      chain = described_class.observe("chain-test", { input: { query: "test" } }, as_type: :chain)
      retriever = described_class.observe("retriever-test", { input: { query: "test" } }, as_type: :retriever)
      evaluator = described_class.observe("evaluator-test", { input: { response: "test" } }, as_type: :evaluator)
      guardrail = described_class.observe("guardrail-test", { input: { content: "test" } }, as_type: :guardrail)
      embedding_attrs = { input: { texts: ["test"] }, model: "text-embedding-ada-002" }
      embedding = described_class.observe("embedding-test", embedding_attrs, as_type: :embedding)

      expect(span).to be_a(Langfuse::Span)
      expect(gen).to be_a(Langfuse::Generation)
      expect(event).to be_a(Langfuse::Event)
      expect(agent).to be_a(Langfuse::Agent)
      expect(tool).to be_a(Langfuse::Tool)
      expect(chain).to be_a(Langfuse::Chain)
      expect(retriever).to be_a(Langfuse::Retriever)
      expect(evaluator).to be_a(Langfuse::Evaluator)
      expect(guardrail).to be_a(Langfuse::Guardrail)
      expect(embedding).to be_a(Langfuse::Embedding)
    end

    context "with invalid observation types" do
      it "raises ArgumentError for invalid type" do
        expect do
          described_class.observe("test", {}, as_type: :invalid)
        end.to raise_error(ArgumentError, /Invalid observation type: invalid/)
      end

      it "raises ArgumentError for nil type" do
        expect do
          described_class.observe("test", {}, as_type: nil)
        end.to raise_error(ArgumentError, /Invalid observation type/)
      end
    end
  end
end
