# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::Config, "#span_exporter" do
  let(:config) do
    described_class.new do |candidate|
      candidate.public_key = "pk_test"
      candidate.secret_key = "sk_test"
    end
  end

  let(:exporter) do
    instance_double(
      OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter,
      export: OpenTelemetry::SDK::Trace::Export::SUCCESS,
      force_flush: OpenTelemetry::SDK::Trace::Export::SUCCESS,
      shutdown: OpenTelemetry::SDK::Trace::Export::SUCCESS
    )
  end

  it "defaults to nil" do
    expect(config.span_exporter).to be_nil
  end

  it "accepts an exporter that implements the OpenTelemetry contract" do
    config.span_exporter = exporter

    expect { config.validate_tracing! }.not_to raise_error
  end

  it "rejects an exporter that does not implement the OpenTelemetry contract" do
    config.span_exporter = Object.new

    expect { config.validate_tracing! }.to raise_error(
      Langfuse::ConfigurationError,
      "span_exporter must respond to #export, #force_flush, #shutdown"
    )
  end

  it "keeps exporter validation out of client-only validation" do
    config.span_exporter = Object.new

    expect { config.validate! }.not_to raise_error
  end
end
