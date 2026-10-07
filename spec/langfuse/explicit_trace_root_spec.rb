# frozen_string_literal: true

require "spec_helper"
require "stringio"
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

  it "marks repeated explicit-ID spans and generations without removing their placeholder parents" do
    2.times do |index|
      type = index.zero? ? :span : :generation
      Langfuse.observe("root-#{index}", as_type: type, trace_id: trace_id, input: { step: index }) do |root|
        root.update(output: { complete: true })
      end
    end

    spans = exported_spans.values
    expect(spans.size).to eq(2)
    expect(spans.map(&:span_id).uniq.size).to eq(2)
    expect(spans.map { |span| span.attributes[Langfuse::OtelAttributes::OBSERVATION_TYPE] })
      .to contain_exactly("span", "generation")
    spans.each do |span|
      expect(span.hex_trace_id).to eq(trace_id)
      expect(span.parent_span_id).not_to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
      expect(spans.map(&:span_id)).not_to include(span.parent_span_id)
      expect(span.attributes[root_attribute]).to be(true)
      expect(span.attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
      expect(JSON.parse(span.attributes[Langfuse::OtelAttributes::OBSERVATION_OUTPUT])).to eq("complete" => true)
    end
  end

  it "marks explicit entries but keeps ordinary children under their actual parent" do
    Langfuse.observe("outer", trace_id: trace_id) do |outer|
      outer.start_observation("explicit-child").end
      Langfuse.observe("ambient-child") { |_child| nil }
      Langfuse.observe("nested-entry", trace_id: trace_id) { |_inner| nil }
    end

    spans = exported_spans
    outer = spans.fetch("outer")
    nested = spans.fetch("nested-entry")
    expect(outer.attributes[root_attribute]).to be(true)
    expect(nested.attributes[root_attribute]).to be(true)
    expect(nested.parent_span_id).not_to eq(outer.span_id)
    expect(nested.attributes).not_to have_key(Langfuse::OtelAttributes::IS_APP_ROOT)
    %w[explicit-child ambient-child].each do |name|
      child = spans.fetch(name)
      expect(child.hex_trace_id).to eq(trace_id)
      expect(child.parent_span_id).to eq(outer.span_id)
      expect(child.attributes).not_to have_key(root_attribute)
      expect(child.attributes).not_to have_key(Langfuse::OtelAttributes::IS_APP_ROOT)
    end
  end

  it "sets the root attribute before an explicit-ID event ends" do
    event = Langfuse.start_observation("event", { input: "request", output: "result" },
                                       as_type: :event, trace_id: trace_id)

    expect(event.otel_span.recording?).to be(false)
    span = exported_spans.fetch("event")
    expect(span.attributes[root_attribute]).to be(true)
    expect(span.attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
    expect(JSON.parse(span.attributes[Langfuse::OtelAttributes::OBSERVATION_INPUT])).to eq("request")
    expect(JSON.parse(span.attributes[Langfuse::OtelAttributes::OBSERVATION_OUTPUT])).to eq("result")
  end

  it "preserves propagated attributes and restores the host context after success or an exception" do
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.tracer("host-app").in_span("request") do |host|
      Langfuse.propagate_attributes(user_id: "user-123", session_id: "session-456") do
        previous_context = OpenTelemetry::Context.current
        Langfuse.observe("successful", trace_id: trace_id) { |_observation| nil }
        expect(OpenTelemetry::Context.current).to equal(previous_context)
        expect do
          Langfuse.observe("seeded", trace_id: trace_id) { raise "synthetic failure" }
        end.to raise_error(RuntimeError, "synthetic failure")
        expect(OpenTelemetry::Context.current).to equal(previous_context)
        expect(OpenTelemetry::Trace.current_span).to equal(host)
      end
    end

    span = exported_spans.fetch("seeded")
    expect(span.hex_trace_id).to eq(trace_id)
    expect(span.attributes).to include(root_attribute => true, "user.id" => "user-123", "session.id" => "session-456")
  ensure
    provider&.shutdown
  end

  it "preserves a foreign ambient parent without adding the explicit-ID root attribute" do
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.tracer("host-app").in_span("request") do |host|
      Langfuse.observe("workflow") { |_observation| nil }
      span = exported_spans.fetch("workflow")

      expect(span.trace_id).to eq(host.context.trace_id)
      expect(span.parent_span_id).to eq(host.context.span_id)
      expect(span.attributes).not_to have_key(root_attribute)
      expect(span.attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
      expect(OpenTelemetry::Trace.current_span).to equal(host)
    end
  ensure
    provider&.shutdown
  end

  it "keeps the sampled placeholder behavior with an always-off root sampler" do
    Langfuse.tracer_provider.sampler = OpenTelemetry::SDK::Trace::Samplers.parent_based(
      root: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF
    )
    Langfuse.observe("seeded", trace_id: trace_id) { |_observation| nil }

    expect(exported_spans.fetch("seeded").attributes[root_attribute]).to be(true)
  end

  it "retains explicit-ID correlation when tracing is disabled" do
    Langfuse.configure { |config| config.tracing_enabled = false }
    observation = Langfuse.start_observation("disabled", trace_id: trace_id)

    expect(observation.trace_id).to eq(trace_id)
    expect(observation.otel_span.recording?).to be(false)
    observation.end
    expect(exported_spans).to be_empty
  end

  it "exports the root attribute and child relationship in the native OTLP payload" do
    Langfuse.configure { |config| config.span_exporter = nil }
    request = nil
    endpoint = stub_request(:post, "https://cloud.langfuse.com/api/public/otel/v1/traces")
               .to_return do |http_request|
      request = http_request
      { status: 200, body: "", headers: {} }
    end
    Langfuse.observe("root", trace_id: trace_id, input: "request") do |root|
      root.update(output: "result")
      root.start_observation("child").end
    end
    Langfuse.force_flush

    expect(endpoint).to have_been_requested.once
    expect(request.headers["X-Langfuse-Ingestion-Version"]).to eq("4")
    payload = Zlib::GzipReader.wrap(StringIO.new(request.body), &:read)
    decoded = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(payload)
    spans = decoded.resource_spans.flat_map(&:scope_spans).flat_map(&:spans).to_h { |span| [span.name, span] }
    root = spans.fetch("root")
    attributes = root.attributes.to_h { |attribute| [attribute.key, attribute.value] }
    expect(root.trace_id.unpack1("H*")).to eq(trace_id)
    expect(root.parent_span_id).not_to be_empty
    expect(attributes.fetch(root_attribute).bool_value).to be(true)
    expect(attributes.fetch(Langfuse::OtelAttributes::IS_APP_ROOT).bool_value).to be(true)
    expect(JSON.parse(attributes.fetch(Langfuse::OtelAttributes::OBSERVATION_INPUT).string_value)).to eq("request")
    expect(JSON.parse(attributes.fetch(Langfuse::OtelAttributes::OBSERVATION_OUTPUT).string_value)).to eq("result")
    expect(spans.fetch("child").parent_span_id).to eq(root.span_id)
    expect(spans.fetch("child").attributes.map(&:key)).not_to include(root_attribute)
  end
end
