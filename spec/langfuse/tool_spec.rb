# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"

RSpec.describe Langfuse::Tool do
  let(:tracer_provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
  let(:otel_tracer) { tracer_provider.tracer("test-tracer") }
  let(:otel_span) { otel_tracer.start_span("test-tool") }
  let(:tool) { described_class.new(otel_span, otel_tracer) }

  describe "#type" do
    it "returns 'tool'" do
      expect(tool.type).to eq("tool")
    end
  end

  describe "#update" do
    it "updates tool attributes" do
      tool.update(
        output: { result: "success", count: 42 },
        level: "DEFAULT",
        metadata: { latency: 150 }
      )

      span_data = tool.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "result" => "success",
                                                                                      "count" => 42 })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
      expect(span_data.attributes["langfuse.observation.metadata.latency"]).to eq("150")
    end

    it "returns self for method chaining" do
      result = tool.update(output: { test: true })
      expect(result).to eq(tool)
    end
  end

  describe "integration with Langfuse.start_observation" do
    it "creates tool via start_observation" do
      tool_obj = Langfuse.start_observation("test-tool", { input: { query: "search" } }, as_type: :tool)

      expect(tool_obj).to be_a(described_class)
      expect(tool_obj.type).to eq("tool")
    end
  end

  describe "integration with Span via start_observation" do
    it "creates tool as child of span" do
      parent_span = otel_tracer.start_span("parent-span")
      parent_observation = Langfuse::Span.new(parent_span, otel_tracer)

      tool_obj = parent_observation.start_observation("nested-tool", { input: { query: "test" } }, as_type: :tool)
      expect(tool_obj).to be_a(described_class)
      expect(tool_obj.trace_id).to eq(parent_observation.trace_id)
    end
  end

  describe "attribute setters" do
    it "supports input setter" do
      tool.input = { query: "search" }
      span_data = tool.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "query" => "search" })
    end

    it "supports output setter" do
      tool.output = { result: "success" }
      span_data = tool.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "result" => "success" })
    end

    it "supports metadata setter" do
      tool.metadata = { latency: 150, cache: "miss" }
      span_data = tool.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.metadata.latency"]).to eq("150")
      expect(span_data.attributes["langfuse.observation.metadata.cache"]).to eq("miss")
    end

    it "supports level setter" do
      tool.level = "WARNING"
      span_data = tool.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.level"]).to eq("WARNING")
    end
  end

  describe "#id and #trace_id" do
    it "returns hex-encoded span ID" do
      span_id = tool.id
      expect(span_id).to be_a(String)
      expect(span_id.length).to eq(16) # 8 bytes = 16 hex chars
      expect(span_id).to match(/\A[0-9a-f]{16}\z/)
    end

    it "returns hex-encoded trace ID" do
      trace_id = tool.trace_id
      expect(trace_id).to be_a(String)
      expect(trace_id.length).to eq(32) # 16 bytes = 32 hex chars
      expect(trace_id).to match(/\A[0-9a-f]{32}\z/)
    end
  end

  describe "initialization with attributes" do
    it "sets initial attributes when provided" do
      attrs = { input: { query: "search" }, output: { result: "success" }, level: "DEFAULT" }
      tool_obj = described_class.new(otel_span, otel_tracer, attributes: attrs)
      span_data = tool_obj.otel_span.to_span_data

      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "query" => "search" })
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "result" => "success" })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
    end
  end
end
