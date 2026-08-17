# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::ResilientMetricsReporter do
  let(:logger) { instance_double(Logger, warn: nil) }
  let(:reporter) do
    instance_double(
      OpenTelemetry::SDK::Trace::Export::MetricsReporter,
      add_to_counter: nil,
      record_value: nil,
      observe_value: nil
    )
  end
  let(:wrapped) { described_class.wrap(reporter, logger: logger) }

  it "preserves nil so OpenTelemetry uses its no-op reporter" do
    expect(described_class.wrap(nil, logger: logger)).to be_nil
  end

  it "forwards counters without changing arguments" do
    wrapped.add_to_counter("otel.bsp.exported_spans", increment: 3, labels: { "reason" => "test" })

    expect(reporter).to have_received(:add_to_counter).with(
      "otel.bsp.exported_spans", increment: 3, labels: { "reason" => "test" }
    )
  end

  it "forwards recorded values without changing arguments" do
    wrapped.record_value("otel.test.duration", value: 1.25, labels: { "unit" => "seconds" })

    expect(reporter).to have_received(:record_value).with(
      "otel.test.duration", value: 1.25, labels: { "unit" => "seconds" }
    )
  end

  it "forwards observed values without changing arguments" do
    wrapped.observe_value("otel.bsp.buffer_utilization", value: 0.5, labels: {})

    expect(reporter).to have_received(:observe_value).with(
      "otel.bsp.buffer_utilization", value: 0.5, labels: {}
    )
  end

  it "suppresses reporter failures and warns once across methods" do
    allow(reporter).to receive(:add_to_counter).and_raise("counter failed")
    allow(reporter).to receive(:observe_value).and_raise("gauge failed")

    expect { wrapped.add_to_counter("counter") }.not_to raise_error
    expect { wrapped.observe_value("gauge", value: 1) }.not_to raise_error

    expect(logger).to have_received(:warn).once.with(/#add_to_counter failed with RuntimeError/)
  end

  it "suppresses logger failures" do
    allow(reporter).to receive(:record_value).and_raise("reporter failed")
    allow(logger).to receive(:warn).and_raise("logger failed")

    expect { wrapped.record_value("value", value: 1) }.not_to raise_error
  end

  it "emits one warning when concurrent reporter calls fail" do
    allow(reporter).to receive(:add_to_counter).and_raise("reporter failed")

    threads = 20.times.map { Thread.new { wrapped.add_to_counter("counter") } }
    threads.each(&:value)

    expect(logger).to have_received(:warn).once
  end
end
