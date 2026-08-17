# frozen_string_literal: true

RSpec.describe Langfuse::Config do
  describe "telemetry state" do
    it "enables telemetry by default" do
      config = described_class.new

      expect(config.tracing_enabled).to be true
      expect(config.telemetry_enabled?).to be true
      expect(config.trace_export_enabled?).to be true
    end

    it "reads LANGFUSE_TRACING_ENABLED without case sensitivity" do
      ENV["LANGFUSE_TRACING_ENABLED"] = "FALSE"

      config = described_class.new

      expect(config.tracing_enabled).to be false
      expect(config.telemetry_enabled?).to be false
      expect(config.trace_export_enabled?).to be false
    ensure
      ENV.delete("LANGFUSE_TRACING_ENABLED")
    end

    it "lets Ruby configuration override LANGFUSE_TRACING_ENABLED" do
      ENV["LANGFUSE_TRACING_ENABLED"] = "false"

      config = described_class.new { |candidate| candidate.tracing_enabled = true }

      expect(config.telemetry_enabled?).to be true
    ensure
      ENV.delete("LANGFUSE_TRACING_ENABLED")
    end

    it "disables only trace export when OTEL_SDK_DISABLED is true" do
      ENV["OTEL_SDK_DISABLED"] = "TRUE"

      config = described_class.new { |candidate| candidate.tracing_enabled = true }

      expect(config.telemetry_enabled?).to be true
      expect(config.trace_export_enabled?).to be false
    ensure
      ENV.delete("OTEL_SDK_DISABLED")
    end

    it "keeps telemetry enabled for other OTEL_SDK_DISABLED values" do
      ENV["OTEL_SDK_DISABLED"] = "1"

      config = described_class.new

      expect(config.telemetry_enabled?).to be true
      expect(config.trace_export_enabled?).to be true
    ensure
      ENV.delete("OTEL_SDK_DISABLED")
    end

    it "rejects an invalid LANGFUSE_TRACING_ENABLED value" do
      ENV["LANGFUSE_TRACING_ENABLED"] = "sometimes"

      expect { described_class.new }.to raise_error(
        Langfuse::ConfigurationError,
        "LANGFUSE_TRACING_ENABLED must be true or false"
      )
    ensure
      ENV.delete("LANGFUSE_TRACING_ENABLED")
    end

    it "rejects a non-Boolean tracing_enabled value" do
      config = described_class.new
      config.tracing_enabled = "false"

      expect { config.validate! }.to raise_error(
        Langfuse::ConfigurationError,
        "tracing_enabled must be true or false"
      )
    end
  end
end
