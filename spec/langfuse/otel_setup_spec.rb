# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::OtelSetup do
  let(:logger) { instance_double(Logger, info: nil, debug: nil, warn: nil) }
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:config) do
    Langfuse::Config.new do |c|
      c.public_key = "pk_test_123"
      c.secret_key = "sk_test_456"
      c.base_url = "https://api.langfuse.test"
      c.tracing_async = false
      c.batch_size = 10
      c.flush_interval = 1
      c.logger = logger
    end
  end

  before do
    described_class.shutdown(timeout: 1) if described_class.initialized?
    allow(described_class).to receive(:build_exporter).and_return(exporter)
  end

  after do
    described_class.shutdown(timeout: 1) if described_class.initialized?
  end

  describe ".setup" do
    it "initializes the tracer provider" do
      described_class.setup(config)

      expect(described_class.tracer_provider).to be_a(OpenTelemetry::SDK::Trace::TracerProvider)
      expect(described_class.initialized?).to be true
    end

    it "does not mutate the global tracer provider" do
      original_global_provider = OpenTelemetry.tracer_provider

      described_class.setup(config)

      expect(OpenTelemetry.tracer_provider).to eq(original_global_provider)
    end

    it "does not mutate the global propagator" do
      original_global_propagation = OpenTelemetry.propagation

      described_class.setup(config)

      expect(OpenTelemetry.propagation).to eq(original_global_propagation)
    end

    it "reuses the existing provider for identical tracing config" do
      provider = described_class.setup(config)

      expect(logger).to receive(:debug).with(/reusing existing tracer provider/)
      expect(described_class.setup(config)).to equal(provider)
    end

    it "warns and keeps the existing provider when tracing config changes" do
      provider = described_class.setup(config)
      config.environment = "staging"

      expect(logger).to receive(:warn).with(/require Langfuse.reset!/)
      expect(described_class.setup(config)).to equal(provider)
    end

    it "shuts down unpublished providers lost in the setup race" do
      candidate_provider = instance_double(OpenTelemetry::SDK::Trace::TracerProvider, shutdown: nil)
      existing_provider = instance_double(OpenTelemetry::SDK::Trace::TracerProvider)

      allow(described_class).to receive_messages(
        build_tracer_provider: candidate_provider,
        publish_provider: [existing_provider, false],
        existing_provider_for: existing_provider
      )

      expect(candidate_provider).to receive(:shutdown).with(timeout: 30)
      expect(described_class.setup(config)).to equal(existing_provider)
    end

    it "validates should_export_span in setup" do
      config.should_export_span = "bad"

      expect { described_class.setup(config) }.to raise_error(
        Langfuse::ConfigurationError,
        "should_export_span must respond to #call"
      )
    end
  end

  describe ".shutdown" do
    it "is safe before initialization" do
      expect { described_class.shutdown(timeout: 1) }.not_to raise_error
    end
  end

  describe ".force_flush" do
    it "is safe before initialization" do
      expect { described_class.force_flush(timeout: 1) }.not_to raise_error
    end
  end

  describe "lazy module-level setup" do
    it "does not initialize tracing during Langfuse.configure" do
      Langfuse.configure do |c|
        c.public_key = config.public_key
        c.secret_key = config.secret_key
        c.base_url = config.base_url
        c.logger = logger
      end

      expect(described_class.initialized?).to be false
    end

    it "raises from Langfuse.tracer_provider when tracing is not ready" do
      Langfuse.reset!
      Langfuse.configure do |c|
        c.public_key = nil
        c.secret_key = nil
        c.base_url = nil
        c.logger = logger
      end

      expect { Langfuse.tracer_provider }.to raise_error(
        Langfuse::ConfigurationError,
        /Langfuse tracing is disabled/
      )
    end

    it "initializes once when Langfuse.tracer_provider is called concurrently" do
      Langfuse.reset!
      Langfuse.configure do |c|
        c.public_key = config.public_key
        c.secret_key = config.secret_key
        c.base_url = config.base_url
        c.logger = logger
      end

      providers = Queue.new
      threads = 5.times.map do
        Thread.new { providers << Langfuse.tracer_provider }
      end
      threads.each(&:join)

      resolved = 5.times.map { providers.pop }
      expect(resolved.map(&:object_id).uniq.length).to eq(1)
    end
  end

  describe "export behavior" do
    before do
      Langfuse.reset!
      Langfuse.configure do |c|
        c.public_key = config.public_key
        c.secret_key = config.secret_key
        c.base_url = config.base_url
        c.tracing_async = false
        c.batch_size = 10
        c.flush_interval = 1
        c.logger = logger
      end
    end

    it "exports Langfuse-created spans without exporting ambient global spans" do
      OpenTelemetry.tracer_provider.tracer("dalli").start_span("cache-span").finish
      span = Langfuse.observe("langfuse-span")
      span.end
      Langfuse.force_flush(timeout: 1)

      expect(exporter.finished_spans.map(&:name)).to eq(["langfuse-span"])
    end

    it "exports known LLM scopes after explicit global installation" do
      OpenTelemetry.tracer_provider = Langfuse.tracer_provider
      OpenTelemetry.tracer_provider.tracer("langsmith.client").start_span("global-span").finish
      Langfuse.force_flush(timeout: 1)

      expect(exporter.finished_spans.map(&:name)).to eq(["global-span"])
    end

    it "allows custom filters to drop globally installed spans again" do
      Langfuse.reset!
      Langfuse.configure do |c|
        c.public_key = config.public_key
        c.secret_key = config.secret_key
        c.base_url = config.base_url
        c.tracing_async = false
        c.should_export_span = ->(_span) { false }
        c.logger = logger
      end

      OpenTelemetry.tracer_provider = Langfuse.tracer_provider
      OpenTelemetry.tracer_provider.tracer("langsmith.client").start_span("global-span").finish
      Langfuse.force_flush(timeout: 1)

      expect(exporter.finished_spans).to be_empty
    end
  end
end
