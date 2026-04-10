# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"

RSpec.describe Langfuse::TraceId do
  describe ".create" do
    it "returns a 32-character lowercase hex string" do
      trace_id = described_class.create
      expect(trace_id).to be_a(String)
      expect(trace_id.length).to eq(32)
      expect(trace_id).to match(/\A[0-9a-f]{32}\z/)
    end

    it "is deterministic for the same seed" do
      first = described_class.create(seed: "order-123")
      second = described_class.create(seed: "order-123")
      expect(first).to eq(second)
    end

    it "produces different IDs for different seeds" do
      expect(described_class.create(seed: "a")).not_to eq(described_class.create(seed: "b"))
    end

    it "coerces non-string seeds to strings" do
      expect(described_class.create(seed: 42)).to eq(described_class.create(seed: "42"))
    end

    it "returns different IDs across calls when unseeded" do
      ids = Array.new(5) { described_class.create }
      expect(ids.uniq.length).to eq(5)
    end

    it "matches the SHA-256 reference algorithm for a known seed" do
      expected = Digest::SHA256.digest("order-12345")[0, 16].unpack1("H*")
      expect(described_class.create(seed: "order-12345")).to eq(expected)
    end
  end

  describe ".create_observation_id" do
    it "returns a 16-character lowercase hex string" do
      id = described_class.create_observation_id
      expect(id).to match(/\A[0-9a-f]{16}\z/)
    end

    it "is deterministic for the same seed" do
      first = described_class.create_observation_id(seed: "span-x")
      second = described_class.create_observation_id(seed: "span-x")
      expect(first).to eq(second)
    end

    it "matches the SHA-256 reference algorithm for a known seed" do
      expected = Digest::SHA256.digest("span-x")[0, 8].unpack1("H*")
      expect(described_class.create_observation_id(seed: "span-x")).to eq(expected)
    end
  end

  describe ".valid?" do
    it "returns true for a 32-char lowercase hex string" do
      expect(described_class.valid?("a" * 32)).to be(true)
      expect(described_class.valid?("0123456789abcdef0123456789abcdef")).to be(true)
    end

    it "returns false for wrong length" do
      expect(described_class.valid?("a" * 31)).to be(false)
      expect(described_class.valid?("a" * 33)).to be(false)
    end

    it "returns false for uppercase hex" do
      expect(described_class.valid?("A" * 32)).to be(false)
    end

    it "returns false for non-hex characters" do
      expect(described_class.valid?("g" * 32)).to be(false)
    end

    it "returns false for nil or non-strings" do
      expect(described_class.valid?(nil)).to be(false)
      expect(described_class.valid?(12_345)).to be(false)
    end

    it "returns false when the string contains a newline (anchor check)" do
      # \A/\z anchors must reject multiline input that ^/$ would wrongly accept
      expect(described_class.valid?("#{'a' * 32}\nextra")).to be(false)
    end
  end

  describe ".valid_observation_id?" do
    it "returns true for a 16-char lowercase hex string" do
      expect(described_class.valid_observation_id?("a" * 16)).to be(true)
    end

    it "returns false for wrong length" do
      expect(described_class.valid_observation_id?("a" * 15)).to be(false)
    end

    it "returns false for nil" do
      expect(described_class.valid_observation_id?(nil)).to be(false)
    end
  end

  describe ".to_span_context" do
    before do
      OpenTelemetry.tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    end

    it "returns a SpanContext carrying the provided trace ID" do
      hex_trace_id = described_class.create(seed: "order-123")
      ctx = described_class.to_span_context(hex_trace_id)

      expect(ctx).to be_a(OpenTelemetry::Trace::SpanContext)
      expect(ctx.trace_id.unpack1("H*")).to eq(hex_trace_id)
    end

    it "sets the SAMPLED trace flag" do
      ctx = described_class.to_span_context(described_class.create(seed: "x"))
      expect(ctx.trace_flags.sampled?).to be(true)
    end

    it "raises ArgumentError for an invalid trace ID" do
      expect { described_class.to_span_context("not-valid") }.to raise_error(ArgumentError, /Invalid trace_id/)
    end

    it "raises ArgumentError for nil" do
      expect { described_class.to_span_context(nil) }.to raise_error(ArgumentError)
    end
  end
end
