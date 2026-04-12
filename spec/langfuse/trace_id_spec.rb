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

    it "raises ArgumentError for non-String seeds" do
      expect { described_class.create(seed: 42) }.to raise_error(ArgumentError, /must be a String/)
      expect { described_class.create(seed: :foo) }.to raise_error(ArgumentError, /must be a String/)
    end

    it "normalizes ASCII-8BIT encoded strings to UTF-8" do
      utf8 = "café"
      binary = utf8.dup.force_encoding(Encoding::ASCII_8BIT)
      expect(described_class.create(seed: binary)).to eq(described_class.create(seed: utf8))
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

  describe ".valid?" do
    it "returns true for a 32-char lowercase hex string" do
      expect(described_class.send(:valid?, "a" * 32)).to be(true)
      expect(described_class.send(:valid?, "0123456789abcdef0123456789abcdef")).to be(true)
    end

    it "returns false for wrong length" do
      expect(described_class.send(:valid?, "a" * 31)).to be(false)
      expect(described_class.send(:valid?, "a" * 33)).to be(false)
    end

    it "returns false for uppercase hex" do
      expect(described_class.send(:valid?, "A" * 32)).to be(false)
    end

    it "returns false for non-hex characters" do
      expect(described_class.send(:valid?, "g" * 32)).to be(false)
    end

    it "returns false for nil or non-strings" do
      expect(described_class.send(:valid?, nil)).to be(false)
      expect(described_class.send(:valid?, 12_345)).to be(false)
    end

    it "returns false when the string contains a newline (anchor check)" do
      expect(described_class.send(:valid?, "#{'a' * 32}\nextra")).to be(false)
    end

    it "returns false for the all-zero W3C invalid trace ID" do
      expect(described_class.send(:valid?, "0" * 32)).to be(false)
    end
  end

  describe ".to_span_context" do
    before do
      OpenTelemetry.tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    end

    it "returns a SpanContext carrying the provided trace ID" do
      hex_trace_id = described_class.create(seed: "order-123")
      ctx = described_class.send(:to_span_context, hex_trace_id)

      expect(ctx).to be_a(OpenTelemetry::Trace::SpanContext)
      expect(ctx.trace_id.unpack1("H*")).to eq(hex_trace_id)
    end

    it "sets the SAMPLED trace flag" do
      ctx = described_class.send(:to_span_context, described_class.create(seed: "x"))
      expect(ctx.trace_flags.sampled?).to be(true)
    end

    it "marks the span context as non-remote (cross-SDK parity lock)" do
      ctx = described_class.send(:to_span_context, described_class.create(seed: "parity"))
      expect(ctx.remote?).to be(false)
    end

    it "raises ArgumentError for an invalid trace ID" do
      expect { described_class.send(:to_span_context, "not-valid") }.to raise_error(ArgumentError, /Invalid trace_id/)
    end

    it "raises ArgumentError for nil" do
      expect { described_class.send(:to_span_context, nil) }.to raise_error(ArgumentError)
    end
  end
end
