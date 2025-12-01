# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"

RSpec.describe Langfuse::Embedding do
  let(:tracer_provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
  let(:otel_tracer) { tracer_provider.tracer("test-tracer") }
  let(:otel_span) { otel_tracer.start_span("test-embedding") }
  let(:embedding) { described_class.new(otel_span, otel_tracer) }

  describe "#type" do
    it "returns 'embedding'" do
      expect(embedding.type).to eq("embedding")
    end
  end

  describe "#update" do
    it "updates embedding attributes" do
      embedding.update(
        output: { vectors: [[0.1, 0.2, 0.3]] },
        usage_details: { prompt_tokens: 10, total_tokens: 10 },
        model: "text-embedding-ada-002"
      )

      span_data = embedding.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "vectors" => [[0.1, 0.2, 0.3]] })
      expect(JSON.parse(span_data.attributes["langfuse.observation.usage_details"])).to eq({ "prompt_tokens" => 10,
                                                                                             "total_tokens" => 10 })
      expect(span_data.attributes["langfuse.observation.model.name"]).to eq("text-embedding-ada-002")
    end

    it "returns self for method chaining" do
      result = embedding.update(output: { test: true })
      expect(result).to eq(embedding)
    end
  end

  describe "integration with Langfuse.start_observation" do
    it "creates embedding via start_observation" do
      embedding_obj = Langfuse.start_observation("test-embedding",
                                                 { input: { texts: ["test"] }, model: "text-embedding-ada-002" },
                                                 as_type: :embedding)

      expect(embedding_obj).to be_a(described_class)
      expect(embedding_obj.type).to eq("embedding")
    end
  end

  describe "integration with Span via start_observation" do
    it "creates embedding as child of span" do
      parent_span = otel_tracer.start_span("parent-span")
      parent_observation = Langfuse::Span.new(parent_span, otel_tracer)

      embedding_obj = parent_observation.start_observation("nested-embedding",
                                                           { input: { texts: ["test"] },
                                                             model: "text-embedding-ada-002" },
                                                           as_type: :embedding)
      expect(embedding_obj).to be_a(described_class)
      expect(embedding_obj.trace_id).to eq(parent_observation.trace_id)
    end
  end

  describe "attribute setters" do
    it "supports input setter" do
      embedding.input = { texts: ["test"] }
      span_data = embedding.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "texts" => ["test"] })
    end

    it "supports output setter" do
      embedding.output = { vectors: [[0.1, 0.2]] }
      span_data = embedding.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "vectors" => [[0.1, 0.2]] })
    end

    it "supports metadata setter" do
      embedding.metadata = { dimension: 1536, model: "ada-002" }
      span_data = embedding.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.metadata.dimension"]).to eq("1536")
      expect(span_data.attributes["langfuse.observation.metadata.model"]).to eq("ada-002")
    end

    it "supports level setter" do
      embedding.level = "WARNING"
      span_data = embedding.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.level"]).to eq("WARNING")
    end

    it "supports usage setter" do
      embedding.usage = { prompt_tokens: 10, total_tokens: 10 }
      span_data = embedding.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.usage_details"])).to eq({ "prompt_tokens" => 10,
                                                                                             "total_tokens" => 10 })
    end

    it "supports model setter" do
      embedding.model = "text-embedding-ada-002"
      span_data = embedding.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.model.name"]).to eq("text-embedding-ada-002")
    end

    it "supports model_parameters setter" do
      embedding.model_parameters = { temperature: 0.0 }
      span_data = embedding.otel_span.to_span_data
      expect(JSON.parse(span_data.attributes["langfuse.observation.model.parameters"])).to eq({ "temperature" => 0.0 })
    end
  end

  describe "#id and #trace_id" do
    it "returns hex-encoded span ID" do
      span_id = embedding.id
      expect(span_id).to be_a(String)
      expect(span_id.length).to eq(16) # 8 bytes = 16 hex chars
      expect(span_id).to match(/\A[0-9a-f]{16}\z/)
    end

    it "returns hex-encoded trace ID" do
      trace_id = embedding.trace_id
      expect(trace_id).to be_a(String)
      expect(trace_id.length).to eq(32) # 16 bytes = 32 hex chars
      expect(trace_id).to match(/\A[0-9a-f]{32}\z/)
    end
  end

  describe "initialization with attributes" do
    it "sets initial attributes when provided" do
      attrs = { input: { texts: ["test"] }, output: { vectors: [[0.1, 0.2]] }, model: "text-embedding-ada-002",
                usage_details: { prompt_tokens: 10 } }
      embedding_obj = described_class.new(otel_span, otel_tracer, attributes: attrs)
      span_data = embedding_obj.otel_span.to_span_data

      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "texts" => ["test"] })
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "vectors" => [[0.1, 0.2]] })
      expect(span_data.attributes["langfuse.observation.model.name"]).to eq("text-embedding-ada-002")
      expect(JSON.parse(span_data.attributes["langfuse.observation.usage_details"])).to eq({ "prompt_tokens" => 10 })
    end
  end
end
