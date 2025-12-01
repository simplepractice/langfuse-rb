# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"

RSpec.describe Langfuse::Chain do
  let(:tracer_provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
  let(:otel_tracer) { tracer_provider.tracer("test-tracer") }
  let(:otel_span) { otel_tracer.start_span("test-chain") }
  let(:chain) { described_class.new(otel_span, otel_tracer) }

  describe "#type" do
    it "returns 'chain'" do
      expect(chain.type).to eq("chain")
    end
  end

  describe "#update" do
    it "updates chain attributes" do
      chain.update(
        output: { steps_completed: 5, final_result: "success" },
        level: "DEFAULT",
        metadata: { efficiency: 0.87 }
      )

      span_data = chain.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "steps_completed" => 5,
                                                                                      "final_result" => "success" })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
      expect(span_data.attributes["langfuse.observation.metadata.efficiency"]).to eq("0.87")
    end

    it "returns self for method chaining" do
      result = chain.update(output: { test: true })
      expect(result).to eq(chain)
    end
  end

  describe "integration with Langfuse.start_observation" do
    it "creates chain via start_observation" do
      chain_obj = Langfuse.start_observation("test-chain", { input: { query: "test" } }, as_type: :chain)

      expect(chain_obj).to be_a(described_class)
      expect(chain_obj.type).to eq("chain")
    end
  end

  describe "integration with Span via start_observation" do
    it "creates chain as child of span" do
      parent_span = otel_tracer.start_span("parent-span")
      parent_observation = Langfuse::Span.new(parent_span, otel_tracer)

      chain_obj = parent_observation.start_observation("nested-chain", { input: { query: "test" } }, as_type: :chain)
      expect(chain_obj).to be_a(described_class)
      expect(chain_obj.trace_id).to eq(parent_observation.trace_id)
    end
  end

  describe "attribute setters" do
    it "supports input setter" do
      chain.input = { query: "test" }
      span_data = chain.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "query" => "test" })
    end

    it "supports output setter" do
      chain.output = { steps_completed: 3 }
      span_data = chain.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "steps_completed" => 3 })
    end

    it "supports metadata setter" do
      chain.metadata = { efficiency: 0.87, steps: 5 }
      span_data = chain.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.metadata.efficiency"]).to eq("0.87")
      expect(span_data.attributes["langfuse.observation.metadata.steps"]).to eq("5")
    end

    it "supports level setter" do
      chain.level = "WARNING"
      span_data = chain.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.level"]).to eq("WARNING")
    end
  end

  describe "#id and #trace_id" do
    it "returns hex-encoded span ID" do
      span_id = chain.id
      expect(span_id).to be_a(String)
      expect(span_id.length).to eq(16) # 8 bytes = 16 hex chars
      expect(span_id).to match(/\A[0-9a-f]{16}\z/)
    end

    it "returns hex-encoded trace ID" do
      trace_id = chain.trace_id
      expect(trace_id).to be_a(String)
      expect(trace_id.length).to eq(32) # 16 bytes = 32 hex chars
      expect(trace_id).to match(/\A[0-9a-f]{32}\z/)
    end
  end

  describe "initialization with attributes" do
    it "sets initial attributes when provided" do
      attrs = { input: { query: "test" }, output: { steps_completed: 3 }, level: "DEFAULT" }
      chain_obj = described_class.new(otel_span, otel_tracer, attributes: attrs)
      span_data = chain_obj.otel_span.to_span_data

      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "query" => "test" })
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "steps_completed" => 3 })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
    end
  end
end
