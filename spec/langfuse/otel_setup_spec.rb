# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::OtelSetup do
  let(:public_key) { "pk_test_123" }
  let(:secret_key) { "sk_test_456" }
  let(:base_url) { "https://api.langfuse.test" }

  let(:config) do
    Langfuse::Config.new do |c|
      c.public_key = public_key
      c.secret_key = secret_key
      c.base_url = base_url
      c.tracing_async = true
      c.batch_size = 50
      c.flush_interval = 10
    end
  end

  before do
    # Reset OTel setup before each test
    described_class.shutdown(timeout: 1) if described_class.initialized?

    # Stub OTLP endpoint
    stub_request(:post, "#{base_url}/api/public/otel/v1/traces")
      .to_return(status: 200, body: "", headers: {})
  end

  after do
    # Clean up after each test
    described_class.shutdown(timeout: 1) if described_class.initialized?
  end

  describe ".setup" do
    it "initializes the tracer provider" do
      described_class.setup(config)

      expect(described_class.tracer_provider).not_to be_nil
      expect(described_class.initialized?).to be true
    end

    it "sets the global tracer provider" do
      described_class.setup(config)

      expect(OpenTelemetry.tracer_provider).to eq(described_class.tracer_provider)
    end

    it "configures W3C TraceContext propagator when none is set" do
      described_class.setup(config)

      expect(OpenTelemetry.propagation).to be_a(OpenTelemetry::Trace::Propagation::TraceContext::TextMapPropagator)
    end

    it "does not overwrite existing propagator" do
      custom_propagator = OpenTelemetry::Trace::Propagation::TraceContext::TextMapPropagator.new
      OpenTelemetry.propagation = custom_propagator

      described_class.setup(config)

      expect(OpenTelemetry.propagation).to eq(custom_propagator)
    end

    it "logs initialization message" do
      expect(config.logger).to receive(:info).with(/Langfuse tracing initialized/)

      described_class.setup(config)
    end

    context "with async mode enabled" do
      before do
        config.tracing_async = true
      end

      it "logs async mode" do
        expect(config.logger).to receive(:info).with(/async mode/)

        described_class.setup(config)
      end

      it "creates a BatchSpanProcessor" do
        described_class.setup(config)

        # Verify tracer can create spans (indicating processor is working)
        tracer = OpenTelemetry.tracer_provider.tracer("test")
        expect { tracer.in_span("test") { |span| } }.not_to raise_error
      end
    end

    context "with async mode disabled" do
      before do
        config.tracing_async = false
      end

      it "logs sync mode" do
        expect(config.logger).to receive(:info).with(/sync mode/)

        described_class.setup(config)
      end

      it "creates a SimpleSpanProcessor" do
        described_class.setup(config)

        # Verify tracer can create spans (indicating processor is working)
        tracer = OpenTelemetry.tracer_provider.tracer("test")
        expect { tracer.in_span("test") { |span| } }.not_to raise_error
      end
    end
  end

  describe ".shutdown" do
    context "when initialized" do
      before do
        described_class.setup(config)
      end

      it "shuts down the tracer provider" do
        described_class.shutdown(timeout: 1)

        expect(described_class.tracer_provider).to be_nil
        expect(described_class.initialized?).to be false
      end

      it "accepts a custom timeout" do
        expect { described_class.shutdown(timeout: 5) }.not_to raise_error
      end
    end

    context "when not initialized" do
      it "does not raise an error" do
        expect { described_class.shutdown }.not_to raise_error
      end
    end
  end

  describe ".force_flush" do
    context "when initialized" do
      before do
        described_class.setup(config)
      end

      it "flushes pending spans" do
        expect { described_class.force_flush(timeout: 1) }.not_to raise_error
      end

      it "accepts a custom timeout" do
        expect { described_class.force_flush(timeout: 5) }.not_to raise_error
      end
    end

    context "when not initialized" do
      it "does not raise an error" do
        expect { described_class.force_flush }.not_to raise_error
      end
    end
  end

  describe ".initialized?" do
    it "returns false when not initialized" do
      expect(described_class.initialized?).to be false
    end

    it "returns true when initialized" do
      described_class.setup(config)

      expect(described_class.initialized?).to be true
    end

    it "returns false after shutdown" do
      described_class.setup(config)
      described_class.shutdown(timeout: 1)

      expect(described_class.initialized?).to be false
    end
  end

  describe "integration with Langfuse.configure" do
    it "auto-initializes OTel" do
      Langfuse.configure do |c|
        c.public_key = public_key
        c.secret_key = secret_key
        c.base_url = base_url
      end

      expect(described_class.initialized?).to be true
    end
  end

  describe "integration with global tracer" do
    before do
      Langfuse.configure do |c|
        c.public_key = public_key
        c.secret_key = secret_key
        c.base_url = base_url
        c.tracing_async = false # Sync mode for predictable testing
      end
    end

    it "sends spans to Langfuse API" do
      # Create a span directly using OpenTelemetry
      otel_tracer = OpenTelemetry.tracer_provider.tracer("test")
      otel_tracer.in_span("test-span") do |_span|
        # Span is automatically sent when it ends
      end

      # Force flush to send immediately
      Langfuse.force_flush(timeout: 1)

      # Verify OTLP endpoint was called
      expect(WebMock).to have_requested(:post, "#{base_url}/api/public/otel/v1/traces").at_least_once
    end
  end
end
