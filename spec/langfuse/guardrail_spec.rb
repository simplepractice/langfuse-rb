# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"

RSpec.describe Langfuse::Guardrail do
  let(:tracer_provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
  let(:otel_tracer) { tracer_provider.tracer("test-tracer") }
  let(:otel_span) { otel_tracer.start_span("test-guardrail") }
  let(:guardrail) { described_class.new(otel_span, otel_tracer) }

  describe "#type" do
    it "returns 'guardrail'" do
      expect(guardrail.type).to eq("guardrail")
    end
  end

  describe "#update" do
    it "updates guardrail attributes" do
      guardrail.update(
        output: { safe: true, risk_score: 0.15, violations: [] },
        level: "DEFAULT",
        metadata: { policy_version: "v2" }
      )

      span_data = guardrail.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "safe" => true,
                                                                                      "risk_score" => 0.15,
                                                                                      "violations" => [] })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
      expect(span_data.attributes["langfuse.observation.metadata.policy_version"]).to eq("v2")
    end

    it "returns self for method chaining" do
      result = guardrail.update(output: { test: true })
      expect(result).to eq(guardrail)
    end
  end

  describe "integration with Langfuse.start_observation" do
    it "creates guardrail via start_observation" do
      guardrail_obj = Langfuse.start_observation("test-guardrail", { input: { content: "test" } }, as_type: :guardrail)

      expect(guardrail_obj).to be_a(described_class)
      expect(guardrail_obj.type).to eq("guardrail")
    end
  end

  describe "integration with Span via start_observation" do
    it "creates guardrail as child of span" do
      parent_span = otel_tracer.start_span("parent-span")
      parent_observation = Langfuse::Span.new(parent_span, otel_tracer)

      guardrail_obj = parent_observation.start_observation("nested-guardrail", { input: { content: "test" } },
                                                           as_type: :guardrail)
      expect(guardrail_obj).to be_a(described_class)
      expect(guardrail_obj.trace_id).to eq(parent_observation.trace_id)
    end
  end

  describe "attribute setters" do
    it "supports input setter" do
      guardrail.input = { content: "test" }
      span_data = guardrail.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "content" => "test" })
    end

    it "supports output setter" do
      guardrail.output = { safe: true }
      span_data = guardrail.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "safe" => true })
    end

    it "supports metadata setter" do
      guardrail.metadata = { policy_version: "v2", strict_mode: true }
      span_data = guardrail.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.metadata.policy_version"]).to eq("v2")
      expect(span_data.attributes["langfuse.observation.metadata.strict_mode"]).to eq("true")
    end

    it "supports level setter" do
      guardrail.level = "WARNING"
      span_data = guardrail.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.level"]).to eq("WARNING")
    end
  end

  describe "#id and #trace_id" do
    it "returns hex-encoded span ID" do
      span_id = guardrail.id
      expect(span_id).to be_a(String)
      expect(span_id.length).to eq(16) # 8 bytes = 16 hex chars
      expect(span_id).to match(/\A[0-9a-f]{16}\z/)
    end

    it "returns hex-encoded trace ID" do
      trace_id = guardrail.trace_id
      expect(trace_id).to be_a(String)
      expect(trace_id.length).to eq(32) # 16 bytes = 32 hex chars
      expect(trace_id).to match(/\A[0-9a-f]{32}\z/)
    end
  end

  describe "initialization with attributes" do
    it "sets initial attributes when provided" do
      attrs = { input: { content: "test" }, output: { safe: true }, level: "DEFAULT" }
      guardrail_obj = described_class.new(otel_span, otel_tracer, attributes: attrs)
      span_data = guardrail_obj.otel_span.to_span_data

      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "content" => "test" })
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "safe" => true })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
    end
  end
end
