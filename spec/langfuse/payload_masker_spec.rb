# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::PayloadMasker do
  let(:logger) { instance_double(Logger, warn: nil) }

  before do
    Langfuse.configuration.logger = logger
  end

  describe ".mask" do
    it "returns the original data when no mask is configured" do
      data = { secret: "raw" }

      expect(described_class.mask(data)).to equal(data)
    end

    it "duplicates cyclic hashes before yielding them to the mask" do
      payload = { "secret" => "raw" }
      payload["self"] = payload

      Langfuse.configuration.mask = lambda do |data:|
        data["secret"] = "[MASKED]"
        data
      end

      masked = described_class.mask(payload)

      expect(masked["secret"]).to eq("[MASKED]")
      expect(masked["self"]).to equal(masked)
      expect(payload["secret"]).to eq("raw")
      expect(payload["self"]).to equal(payload)
    end

    it "duplicates cyclic arrays before yielding them to the mask" do
      payload = []
      payload << payload

      Langfuse.configuration.mask = lambda do |data:|
        data << "masked"
        data
      end

      masked = described_class.mask(payload)

      expect(masked.first).to equal(masked)
      expect(masked.last).to eq("masked")
      expect(payload.length).to eq(1)
      expect(payload.first).to equal(payload)
    end

    it "returns the placeholder and hides payload data when masking fails" do
      warnings = []
      allow(logger).to receive(:warn) { |message| warnings << message }
      Langfuse.configuration.mask = lambda do |data:|
        raise StandardError, "payload leak: #{data.inspect}"
      end

      result = described_class.mask(secret: "do-not-log")

      expect(result).to eq(described_class::MASK_FAILURE_PLACEHOLDER)
      expect(warnings).to contain_exactly("Langfuse: mask function failed (StandardError); using placeholder")
    end
  end
end
