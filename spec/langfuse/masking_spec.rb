# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::Masking do
  describe "FALLBACK" do
    it "matches the JS/Python SDKs' fail-closed string" do
      expect(described_class::FALLBACK).to eq("<fully masked due to failed mask function>")
    end
  end

  describe ".apply" do
    context "when mask is nil" do
      it "returns data unchanged" do
        expect(described_class.apply("secret", mask: nil)).to eq("secret")
      end
    end

    context "when data is nil" do
      it "returns nil without calling mask" do
        mask = ->(data:) { raise "should not be called: #{data}" }
        expect(described_class.apply(nil, mask: mask)).to be_nil
      end
    end

    context "when mask succeeds" do
      it "calls the mask with data: keyword" do
        mask = ->(data:) { data.upcase }
        expect(described_class.apply("hello", mask: mask)).to eq("HELLO")
      end

      it "works with hash data" do
        mask = ->(data:) { data.transform_values { "[REDACTED]" } }
        result = described_class.apply({ name: "secret" }, mask: mask)
        expect(result).to eq({ name: "[REDACTED]" })
      end

      it "works with array data" do
        mask = ->(data:) { data.map { "[REDACTED]" } }
        result = described_class.apply(%w[a b c], mask: mask)
        expect(result).to eq(%w[[REDACTED] [REDACTED] [REDACTED]])
      end
    end

    context "when mask raises" do
      let(:mask) { ->(data:) { raise "boom: #{data.class}" } }

      it "returns the fallback string" do
        expect(described_class.apply("hello", mask: mask)).to eq(described_class::FALLBACK)
      end

      it "logs a warning with the error message" do
        logger = instance_double(Logger)
        allow(Langfuse.configuration).to receive(:logger).and_return(logger)
        allow(logger).to receive(:warn)

        described_class.apply("hello", mask: mask)

        expect(logger).to have_received(:warn).with(/Langfuse: Mask function failed: boom/)
      end
    end

    context "when mask is a Proc" do
      it "accepts a lambda" do
        mask = ->(data:) { "masked-#{data}" }
        expect(described_class.apply("input", mask: mask)).to eq("masked-input")
      end

      it "accepts a method object" do
        mask_obj = Object.new
        def mask_obj.call(data:)
          data.to_s.reverse
        end
        expect(described_class.apply("hello", mask: mask_obj)).to eq("olleh")
      end
    end
  end
end
