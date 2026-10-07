# frozen_string_literal: true

require "spec_helper"
require "zlib"

RSpec.describe "Explicit trace root attributes" do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:trace_id) { Langfuse.create_trace_id(seed: "explicit-root") }
  let(:root_attribute) { "langfuse.internal.as_root" }

  before do
    Langfuse.configure do |config|
      config.span_exporter = exporter
      config.tracing_async = false
    end
  end

  def exported_spans
    Langfuse.force_flush
    exporter.finished_spans.to_h { |span| [span.name, span] }
  end

  it "marks both span and generation entries when they reuse an explicit ID" do
    %i[span generation].each do |type|
      Langfuse.start_observation(type.to_s, as_type: type, trace_id: trace_id).end
    end

    spans = exported_spans
    expect(spans.fetch("span").attributes[root_attribute]).to be(true)
    expect(spans.fetch("generation").attributes[root_attribute]).to be(true)
  end

  it "marks nested explicit entries but not inherited or unseeded observations" do
    Langfuse.observe("outer", trace_id: trace_id) do |outer|
      outer.start_observation("explicit-child").end
      Langfuse.observe("ambient-child") { nil }
      Langfuse.observe("nested-entry", trace_id: trace_id) { nil }
    end
    Langfuse.observe("ordinary") { nil }

    spans = exported_spans
    expect(spans.fetch("outer").attributes[root_attribute]).to be(true)
    expect(spans.fetch("nested-entry").attributes[root_attribute]).to be(true)
    %w[explicit-child ambient-child ordinary].each do |name|
      expect(spans.fetch(name).attributes).not_to have_key(root_attribute)
    end
  end

  it "marks an explicit event before it ends automatically" do
    Langfuse.start_observation("event", as_type: :event, trace_id: trace_id)

    expect(exported_spans.fetch("event").attributes[root_attribute]).to be(true)
  end

  it "keeps a marked explicit entry non-recording when tracing is disabled" do
    Langfuse.configure { |config| config.tracing_enabled = false }
    observation = Langfuse.start_observation("disabled", trace_id: trace_id)
    observation.end

    expect(observation.trace_id).to eq(trace_id)
    expect(observation.otel_span).not_to be_recording
    expect(exported_spans).to be_empty
  end

  it "exports the legacy root attribute and root IO in the native OTLP payload" do
    Langfuse.configure { |config| config.span_exporter = nil }
    payloads = []
    endpoint = stub_request(:post, "https://cloud.langfuse.com/api/public/otel/v1/traces")
               .to_return do |request|
      payloads << Zlib.gunzip(request.body)
      { status: 200, body: "" }
    end
    root = Langfuse.start_observation("root", { input: "request" }, trace_id: trace_id)
    root.update(output: "result")
    root.start_observation("child").end
    root.end
    Langfuse.force_flush

    expect(endpoint).to have_been_requested.once
    message = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(payloads.fetch(0))
    spans = message.resource_spans.flat_map(&:scope_spans).flat_map(&:spans).to_h { |span| [span.name, span] }
    attributes = spans.fetch("root").attributes.to_h { |attribute| [attribute.key, attribute.value] }
    expect(attributes.fetch(root_attribute).bool_value).to be(true)
    expect(attributes.fetch(Langfuse::OtelAttributes::OBSERVATION_INPUT).string_value).to eq("request".to_json)
    expect(attributes.fetch(Langfuse::OtelAttributes::OBSERVATION_OUTPUT).string_value).to eq("result".to_json)
    expect(spans.fetch("child").attributes.map(&:key)).not_to include(root_attribute)
  end
end
