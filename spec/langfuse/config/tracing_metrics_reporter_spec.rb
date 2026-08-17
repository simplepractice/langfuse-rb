# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::Config, "#metrics_reporter" do
  let(:config) do
    described_class.new do |candidate|
      candidate.public_key = "pk_test"
      candidate.secret_key = "sk_test"
    end
  end
  let(:reporter) do
    instance_double(
      OpenTelemetry::SDK::Trace::Export::MetricsReporter,
      add_to_counter: nil,
      record_value: nil,
      observe_value: nil
    )
  end

  it "defaults to nil" do
    expect(config.metrics_reporter).to be_nil
  end

  it "accepts the complete OpenTelemetry reporter contract" do
    config.metrics_reporter = reporter

    expect { config.validate_tracing! }.not_to raise_error
  end

  it "reports every required method when the reporter is invalid" do
    config.metrics_reporter = Object.new

    expect { config.validate_tracing! }.to raise_error(
      Langfuse::ConfigurationError,
      "metrics_reporter must respond to #add_to_counter, #record_value, #observe_value"
    )
  end

  it "rejects a reporter that implements only the methods currently called by the batch processor" do
    incomplete_reporter = Object.new
    def incomplete_reporter.add_to_counter(*) = nil
    def incomplete_reporter.observe_value(*) = nil
    config.metrics_reporter = incomplete_reporter

    expect { config.validate_tracing! }.to raise_error(
      Langfuse::ConfigurationError,
      /#record_value/
    )
  end

  it "keeps tracing-only reporter validity out of client readiness" do
    config.metrics_reporter = Object.new

    expect(config.valid?).to be(true)
    expect { Langfuse::Client.new(config) }.not_to raise_error
  end

  it "fails fast when the explicit tracer provider uses an invalid reporter" do
    Langfuse.configuration = config
    config.metrics_reporter = Object.new

    expect { Langfuse.tracer_provider }.to raise_error(
      Langfuse::ConfigurationError,
      /metrics_reporter must respond to/
    )
  end

  it "warns once and uses no-op tracing for an invalid implicit reporter" do
    logger = instance_double(Logger, debug: nil, info: nil, warn: nil, error: nil)
    config.logger = logger
    config.metrics_reporter = Object.new
    Langfuse.configuration = config

    expect { 2.times { Langfuse.observe("not-exported").end } }.not_to raise_error

    expect(logger).to have_received(:warn).once.with(/metrics_reporter must respond to/)
  end
end
