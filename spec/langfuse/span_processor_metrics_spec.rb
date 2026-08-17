# frozen_string_literal: true

require "spec_helper"
require_relative "../support/blocking_span_exporter"

RSpec.describe Langfuse::SpanProcessor do
  let(:logger) { instance_double(Logger, debug: nil, info: nil, warn: nil, error: nil) }
  let(:reporter) do
    instance_double(
      OpenTelemetry::SDK::Trace::Export::MetricsReporter,
      add_to_counter: nil,
      record_value: nil,
      observe_value: nil
    )
  end
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:config) do
    Langfuse::Config.new do |candidate|
      candidate.public_key = "pk_test"
      candidate.secret_key = "sk_test"
      candidate.tracing_async = false
      candidate.batch_size = 10
      candidate.flush_interval = 30
      candidate.metrics_reporter = reporter
      candidate.logger = logger
    end
  end

  def build_provider(span_exporter)
    processor = described_class.new(config: config, exporter: span_exporter)
    OpenTelemetry::SDK::Trace::TracerProvider.new.tap do |provider|
      provider.add_span_processor(processor)
    end
  end

  def finish_spans(provider, count, prefix: "span")
    tracer = provider.tracer(Langfuse::LANGFUSE_TRACER_NAME)
    count.times { |index| tracer.start_span("#{prefix}-#{index}").finish }
  end

  it "forwards batch processor metrics to the configured reporter" do
    provider = build_provider(exporter)
    finish_spans(provider, 3)

    expect(provider.force_flush(timeout: 1)).to eq(OpenTelemetry::SDK::Trace::Export::SUCCESS)
    expect(reporter).to have_received(:add_to_counter).with(
      "otel.bsp.exported_spans", increment: 3, labels: {}
    )
  ensure
    provider&.shutdown(timeout: 1)
  end

  it "keeps span completion and export safe when the reporter raises" do
    allow(reporter).to receive(:add_to_counter).and_raise("counter failed")
    allow(reporter).to receive(:record_value).and_raise("value failed")
    allow(reporter).to receive(:observe_value).and_raise("observation failed")
    config.tracing_async = true
    config.batch_size = 1
    blocking_exporter = MetricsTestSupport::BlockingSpanExporter.new
    provider = build_provider(blocking_exporter)
    finish_spans(provider, 2)
    blocking_exporter.wait_until_blocked

    expect { finish_spans(provider, 2, prefix: "overflow") }.not_to raise_error
    blocking_exporter.release

    expect(provider.force_flush(timeout: 2)).to eq(OpenTelemetry::SDK::Trace::Export::SUCCESS)
    expect(blocking_exporter.finished_spans.length).to eq(3)
    expect(logger).to have_received(:warn).once
  ensure
    blocking_exporter&.release
    provider&.shutdown(timeout: 1)
  end
end
