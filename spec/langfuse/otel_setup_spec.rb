# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::OtelSetup do
  let(:logger) { instance_double(Logger, info: nil, warn: nil) }

  before do
    Langfuse.reset!
    Langfuse.configure do |config|
      config.public_key = "pk_test"
      config.secret_key = "sk_test"
      config.base_url = "https://cloud.langfuse.com"
      config.logger = logger
    end
  end

  after do
    Langfuse.reset!
  end

  describe ".setup" do
    it "warns and delegates to the global tracer provider" do
      provider = instance_double(OpenTelemetry::SDK::Trace::TracerProvider)

      expect(logger).to receive(:warn).with(/Langfuse::OtelSetup is deprecated/)
      expect(Langfuse).to receive(:tracer_provider).and_return(provider)

      expect(described_class.setup).to equal(provider)
    end
  end

  describe ".tracer_provider" do
    it "returns the current global provider without initializing one" do
      expect(logger).to receive(:warn).with(/Langfuse::OtelSetup is deprecated/)

      expect(described_class.tracer_provider).to be_nil
      expect(Langfuse.client.instance_variable_get(:@tracer_provider)).to be_nil
    end

    it "returns the initialized global provider" do
      provider = Langfuse.tracer_provider

      expect(described_class.tracer_provider).to equal(provider)
    end
  end

  describe ".initialized?" do
    it "reflects whether the global provider has been initialized" do
      expect(described_class.initialized?).to be(false)

      Langfuse.tracer_provider

      expect(described_class.initialized?).to be(true)
    end
  end

  describe ".force_flush" do
    it "delegates to Langfuse.force_flush" do
      expect(Langfuse).to receive(:force_flush).with(timeout: 2)

      described_class.force_flush(timeout: 2)
    end
  end

  describe ".shutdown" do
    it "delegates to Langfuse.shutdown" do
      expect(Langfuse).to receive(:shutdown).with(timeout: 2)

      described_class.shutdown(timeout: 2)
    end
  end
end
