# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Explicit trace ID roots" do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:trace_id) { Langfuse.create_trace_id(seed: "explicit-root") }

  before do
    Langfuse.configure do |config|
      config.span_exporter = exporter
      config.tracing_async = false
    end
  end

  def exported_spans
    Langfuse.force_flush
    exporter.finished_spans
  end

  it "exports repeated explicit IDs as parentless roots with distinct observation IDs" do
    2.times { Langfuse.observe("root", trace_id: trace_id) { nil } }

    spans = exported_spans
    expect(spans.size).to eq(2)
    expect(spans.map(&:hex_trace_id)).to eq([trace_id, trace_id])
    expect(spans.map(&:span_id).uniq.size).to eq(2)
    expect(spans.map(&:parent_span_id)).to all(eq(OpenTelemetry::Trace::INVALID_SPAN_ID))
  end

  it "detaches an explicit root and restores its ambient parent for siblings" do
    Langfuse.observe("ambient") do |ambient|
      Langfuse.observe("seeded", trace_id: trace_id) do
        Langfuse.observe("child") { nil }
      end
      expect(OpenTelemetry::Trace.current_span).to equal(ambient.otel_span)
      Langfuse.observe("sibling") { nil }
    end

    spans = exported_spans.to_h { |span| [span.name, span] }
    expect(spans.fetch("seeded").hex_trace_id).to eq(trace_id)
    expect(spans.fetch("seeded").parent_span_id).to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
    expect(spans.fetch("child").parent_span_id).to eq(spans.fetch("seeded").span_id)
    expect(spans.fetch("sibling").parent_span_id).to eq(spans.fetch("ambient").span_id)
    expect(spans.fetch("sibling").trace_id).to eq(spans.fetch("ambient").trace_id)
  end

  it "marks nested explicit entries as separate application roots for the same trace" do
    Langfuse.observe("outer", trace_id: trace_id) do
      Langfuse.observe("inner", trace_id: trace_id) { nil }
    end

    spans = exported_spans
    expect(spans.size).to eq(2)
    expect(spans.map(&:parent_span_id)).to all(eq(OpenTelemetry::Trace::INVALID_SPAN_ID))
    expect(spans.map(&:attributes)).to all(include(Langfuse::OtelAttributes::IS_APP_ROOT => true))
  end

  it "lets an always-off ParentBased root sampler drop explicit entries" do
    Langfuse.tracer_provider.sampler = OpenTelemetry::SDK::Trace::Samplers.parent_based(
      root: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF
    )
    observation = Langfuse.start_observation("dropped", trace_id: trace_id)
    observation.end

    expect(observation.trace_id).to eq(trace_id)
    expect(observation.otel_span.context.trace_flags).not_to be_sampled
    expect(exported_spans).to be_empty
  end

  it "keeps the captured tracer and ID generator paired across provider replacement" do
    allow(Langfuse).to receive(:otel_tracer_and_id_generator).and_wrap_original do |original|
      captured = original.call
      Langfuse::OtelSetup.shutdown(timeout: 2)
      Langfuse.tracer_provider
      captured
    end

    observation = Langfuse.start_observation("replaced-root", trace_id: trace_id)
    observation.end

    expect(observation.trace_id).to eq(trace_id)
    expect(observation.otel_span).not_to be_recording
    expect(exported_spans).to be_empty
  end

  it "retains the placeholder-parent path when an application replaces the ID generator" do
    Langfuse.tracer_provider.id_generator = OpenTelemetry::Trace
    Langfuse.start_observation("custom-generator", trace_id: trace_id).end

    span = exported_spans.fetch(0)
    expect(span.hex_trace_id).to eq(trace_id)
    expect(span.parent_span_id).not_to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
  end
end
