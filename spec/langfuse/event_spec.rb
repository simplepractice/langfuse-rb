# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"

RSpec.describe Langfuse::Event do
  let(:tracer_provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
  let(:otel_tracer) { tracer_provider.tracer("test-tracer") }
  let(:otel_span) { otel_tracer.start_span("test-event") }
  let(:event) { described_class.new(otel_span, otel_tracer) }

  describe "#type" do
    it "returns 'event'" do
      expect(event.type).to eq("event")
    end
  end

  describe "#update" do
    it "updates event attributes" do
      event.update(
        output: { result: "success" },
        level: "DEFAULT",
        metadata: { source: "api" }
      )

      span_data = event.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "result" => "success" })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
      expect(span_data.attributes["langfuse.observation.metadata.source"]).to eq("api")
    end

    it "returns self for method chaining" do
      result = event.update(output: { test: true })
      expect(result).to eq(event)
    end
  end

  describe "auto-ending behavior via start_observation" do
    let(:parent_span) { otel_tracer.start_span("parent") }
    let(:parent_observation) { Langfuse::Span.new(parent_span, otel_tracer) }

    context "when created without block (stateful API)" do
      it "automatically ends the event" do
        event_obj = parent_observation.start_observation("test-event", {}, as_type: :event)

        expect(event_obj).to be_a(described_class)
        expect(event_obj.type).to eq("event")

        # Verify event is ended by checking span data
        span_data = event_obj.otel_span.to_span_data
        expect(span_data.end_timestamp).not_to be_nil
      end

      it "allows setting attributes before auto-ending" do
        event_obj = parent_observation.start_observation(
          "test-event",
          { input: { action: "click" }, level: "DEFAULT" },
          as_type: :event
        )

        span_data = event_obj.otel_span.to_span_data
        expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "action" => "click" })
        expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
        expect(span_data.end_timestamp).not_to be_nil
      end
    end

    context "when created with block" do
      it "ends after block completes" do
        ended = false
        parent_observation.start_observation("test-event", {}, as_type: :event) do |evt|
          expect(evt).to be_a(described_class)
          expect(evt.type).to eq("event")
          evt.output = { test: true }
          ended = true
        end

        expect(ended).to be true
      end

      it "returns block return value" do
        result = parent_observation.start_observation("test-event", {}, as_type: :event) do |evt|
          evt.output = { test: true }
          "block_result"
        end

        expect(result).to eq("block_result")
      end
    end
  end

  describe "integration with Span via start_observation" do
    it "creates event as child of span" do
      parent_span = otel_tracer.start_span("parent-span")
      parent_observation = Langfuse::Span.new(parent_span, otel_tracer)

      event_obj = parent_observation.start_observation("nested-event", { input: { data: "test" } }, as_type: :event)
      expect(event_obj).to be_a(described_class)
      expect(event_obj.trace_id).to eq(parent_observation.trace_id)
      expect(event_obj.otel_span.to_span_data.end_timestamp).not_to be_nil
    end

    it "creates event as child of generation" do
      parent_span = otel_tracer.start_span("parent-generation")
      parent_observation = Langfuse::Generation.new(parent_span, otel_tracer)

      event_obj = parent_observation.start_observation("streaming-event", { input: { chunk: "data" } }, as_type: :event)
      expect(event_obj).to be_a(described_class)
      expect(event_obj.trace_id).to eq(parent_observation.trace_id)
      expect(event_obj.otel_span.to_span_data.end_timestamp).not_to be_nil
    end
  end

  describe "attribute setters" do
    it "supports input setter" do
      event.input = { query: "test" }
      span_data = event.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "query" => "test" })
    end

    it "supports output setter" do
      event.output = { result: "success" }
      span_data = event.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "result" => "success" })
    end

    it "supports metadata setter" do
      event.metadata = { source: "api", cache: "miss" }
      span_data = event.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.metadata.source"]).to eq("api")
      expect(span_data.attributes["langfuse.observation.metadata.cache"]).to eq("miss")
    end

    it "supports level setter" do
      event.level = "WARNING"
      span_data = event.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.level"]).to eq("WARNING")
    end
  end

  describe "#id and #trace_id" do
    it "returns hex-encoded span ID" do
      span_id = event.id
      expect(span_id).to be_a(String)
      expect(span_id.length).to eq(16) # 8 bytes = 16 hex chars
      expect(span_id).to match(/\A[0-9a-f]{16}\z/)
    end

    it "returns hex-encoded trace ID" do
      trace_id = event.trace_id
      expect(trace_id).to be_a(String)
      expect(trace_id.length).to eq(32) # 16 bytes = 32 hex chars
      expect(trace_id).to match(/\A[0-9a-f]{32}\z/)
    end
  end

  describe "initialization with attributes" do
    it "sets initial attributes when provided" do
      attrs = { input: { action: "click" }, output: { success: true }, level: "DEFAULT" }
      event_obj = described_class.new(otel_span, otel_tracer, attributes: attrs)
      span_data = event_obj.otel_span.to_span_data

      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "action" => "click" })
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "success" => true })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
    end
  end
end
