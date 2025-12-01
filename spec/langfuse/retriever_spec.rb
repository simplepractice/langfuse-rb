# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"

RSpec.describe Langfuse::Retriever do
  let(:tracer_provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
  let(:otel_tracer) { tracer_provider.tracer("test-tracer") }
  let(:otel_span) { otel_tracer.start_span("test-retriever") }
  let(:retriever) { described_class.new(otel_span, otel_tracer) }

  describe "#type" do
    it "returns 'retriever'" do
      expect(retriever.type).to eq("retriever")
    end
  end

  describe "#update" do
    it "updates retriever attributes" do
      retriever.update(
        output: { documents: [], count: 10, avg_similarity: 0.89 },
        level: "DEFAULT",
        metadata: { search_latency: 150 }
      )

      span_data = retriever.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "documents" => [], "count" => 10,
                                                                                      "avg_similarity" => 0.89 })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
      expect(span_data.attributes["langfuse.observation.metadata.search_latency"]).to eq("150")
    end

    it "returns self for method chaining" do
      result = retriever.update(output: { test: true })
      expect(result).to eq(retriever)
    end
  end

  describe "integration with Langfuse.start_observation" do
    it "creates retriever via start_observation" do
      retriever_obj = Langfuse.start_observation("test-retriever", { input: { query: "search" } }, as_type: :retriever)

      expect(retriever_obj).to be_a(described_class)
      expect(retriever_obj.type).to eq("retriever")
    end
  end

  describe "integration with Span via start_observation" do
    it "creates retriever as child of span" do
      parent_span = otel_tracer.start_span("parent-span")
      parent_observation = Langfuse::Span.new(parent_span, otel_tracer)

      retriever_obj = parent_observation.start_observation("nested-retriever", { input: { query: "test" } },
                                                           as_type: :retriever)
      expect(retriever_obj).to be_a(described_class)
      expect(retriever_obj.trace_id).to eq(parent_observation.trace_id)
    end
  end

  describe "attribute setters" do
    it "supports input setter" do
      retriever.input = { query: "search" }
      span_data = retriever.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "query" => "search" })
    end

    it "supports output setter" do
      retriever.output = { documents: [], count: 10 }
      span_data = retriever.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "documents" => [],
                                                                                      "count" => 10 })
    end

    it "supports metadata setter" do
      retriever.metadata = { search_latency: 150, cache: "miss" }
      span_data = retriever.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.metadata.search_latency"]).to eq("150")
      expect(span_data.attributes["langfuse.observation.metadata.cache"]).to eq("miss")
    end

    it "supports level setter" do
      retriever.level = "WARNING"
      span_data = retriever.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.level"]).to eq("WARNING")
    end
  end

  describe "#id and #trace_id" do
    it "returns hex-encoded span ID" do
      span_id = retriever.id
      expect(span_id).to be_a(String)
      expect(span_id.length).to eq(16) # 8 bytes = 16 hex chars
      expect(span_id).to match(/\A[0-9a-f]{16}\z/)
    end

    it "returns hex-encoded trace ID" do
      trace_id = retriever.trace_id
      expect(trace_id).to be_a(String)
      expect(trace_id.length).to eq(32) # 16 bytes = 32 hex chars
      expect(trace_id).to match(/\A[0-9a-f]{32}\z/)
    end
  end

  describe "initialization with attributes" do
    it "sets initial attributes when provided" do
      attrs = { input: { query: "search" }, output: { documents: [], count: 10 }, level: "DEFAULT" }
      retriever_obj = described_class.new(otel_span, otel_tracer, attributes: attrs)
      span_data = retriever_obj.otel_span.to_span_data

      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "query" => "search" })
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "documents" => [],
                                                                                      "count" => 10 })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
    end
  end
end
