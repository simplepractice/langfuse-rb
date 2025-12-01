# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"

RSpec.describe Langfuse::Agent do
  let(:tracer_provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
  let(:otel_tracer) { tracer_provider.tracer("test-tracer") }
  let(:otel_span) { otel_tracer.start_span("test-agent") }
  let(:agent) { described_class.new(otel_span, otel_tracer) }

  describe "#type" do
    it "returns 'agent'" do
      expect(agent.type).to eq("agent")
    end
  end

  describe "#update" do
    it "updates agent attributes" do
      agent.update(
        output: { completed: true, tools_used: 3 },
        level: "DEFAULT",
        metadata: { iterations: 5 }
      )

      span_data = agent.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "completed" => true,
                                                                                      "tools_used" => 3 })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
      expect(span_data.attributes["langfuse.observation.metadata.iterations"]).to eq("5")
    end

    it "returns self for method chaining" do
      result = agent.update(output: { test: true })
      expect(result).to eq(agent)
    end
  end

  describe "integration with Langfuse.start_observation" do
    it "creates agent via start_observation" do
      agent_obj = Langfuse.start_observation("test-agent", { input: { task: "research" } }, as_type: :agent)

      expect(agent_obj).to be_a(described_class)
      expect(agent_obj.type).to eq("agent")
    end
  end

  describe "integration with Span via start_observation" do
    it "creates agent as child of span" do
      parent_span = otel_tracer.start_span("parent-span")
      parent_observation = Langfuse::Span.new(parent_span, otel_tracer)

      agent_obj = parent_observation.start_observation("nested-agent", { input: { task: "test" } }, as_type: :agent)
      expect(agent_obj).to be_a(described_class)
      expect(agent_obj.trace_id).to eq(parent_observation.trace_id)
    end
  end

  describe "attribute setters" do
    it "supports input setter" do
      agent.input = { task: "research" }
      span_data = agent.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "task" => "research" })
    end

    it "supports output setter" do
      agent.output = { completed: true }
      span_data = agent.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "completed" => true })
    end

    it "supports metadata setter" do
      agent.metadata = { iterations: 5, tools_used: 3 }
      span_data = agent.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.metadata.iterations"]).to eq("5")
      expect(span_data.attributes["langfuse.observation.metadata.tools_used"]).to eq("3")
    end

    it "supports level setter" do
      agent.level = "WARNING"
      span_data = agent.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.level"]).to eq("WARNING")
    end
  end

  describe "#id and #trace_id" do
    it "returns hex-encoded span ID" do
      span_id = agent.id
      expect(span_id).to be_a(String)
      expect(span_id.length).to eq(16) # 8 bytes = 16 hex chars
      expect(span_id).to match(/\A[0-9a-f]{16}\z/)
    end

    it "returns hex-encoded trace ID" do
      trace_id = agent.trace_id
      expect(trace_id).to be_a(String)
      expect(trace_id.length).to eq(32) # 16 bytes = 32 hex chars
      expect(trace_id).to match(/\A[0-9a-f]{32}\z/)
    end
  end

  describe "initialization with attributes" do
    it "sets initial attributes when provided" do
      attrs = { input: { task: "research" }, output: { completed: true }, level: "DEFAULT" }
      agent_obj = described_class.new(otel_span, otel_tracer, attributes: attrs)
      span_data = agent_obj.otel_span.to_span_data

      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "task" => "research" })
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "completed" => true })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
    end
  end
end
