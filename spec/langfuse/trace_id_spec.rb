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

  describe ".pin_generation_to" do
    it "makes .generate_trace_id return the raw 16-byte form of the given trace ID for the duration of the block" do
      hex_trace_id = described_class.create(seed: "order-123")

      described_class.pin_generation_to(hex_trace_id) do
        expect(described_class.generate_trace_id).to eq([hex_trace_id].pack("H*"))
      end
    end

    it "reverts to random trace ID generation after the block" do
      pinned = described_class.create(seed: "x")
      described_class.pin_generation_to(pinned) {}

      after = described_class.generate_trace_id
      expect(after.bytesize).to eq(16)
      expect(after).not_to eq([pinned].pack("H*"))
    end

    it "restores the previous pinned trace ID after a nested call, even if it raises" do
      outer = described_class.create(seed: "outer")
      inner = described_class.create(seed: "inner")

      described_class.pin_generation_to(outer) do
        expect do
          described_class.pin_generation_to(inner) { raise "boom" }
        end.to raise_error("boom")

        expect(described_class.generate_trace_id).to eq([outer].pack("H*"))
      end
    end

    it "isolates concurrent sibling fibers from each other's pinned trace ID" do
      trace_id_a = described_class.create(seed: "fiber-a")
      trace_id_b = described_class.create(seed: "fiber-b")
      seen_by_a = nil
      seen_by_b = nil

      fiber_a = Fiber.new do
        described_class.pin_generation_to(trace_id_a) do
          Fiber.yield
          seen_by_a = described_class.generate_trace_id
        end
      end
      fiber_b = Fiber.new do
        described_class.pin_generation_to(trace_id_b) do
          Fiber.yield
          seen_by_b = described_class.generate_trace_id
        end
      end

      # Interleave: both fibers pin their trace ID, yield, then resume and
      # read it back — a shared (non-fiber-local) store would leak b's
      # value into a's read, or vice versa.
      fiber_a.resume
      fiber_b.resume
      fiber_a.resume
      fiber_b.resume

      expect(seen_by_a).to eq([trace_id_a].pack("H*"))
      expect(seen_by_b).to eq([trace_id_b].pack("H*"))
    end

    it "does not leak a child fiber's pinned trace ID back to its parent" do
      parent_trace_id = described_class.create(seed: "parent-fiber")
      child_trace_id = described_class.create(seed: "child-fiber")

      described_class.pin_generation_to(parent_trace_id) do
        Fiber.new do
          described_class.pin_generation_to(child_trace_id) {}
        end.resume

        expect(described_class.generate_trace_id).to eq([parent_trace_id].pack("H*"))
      end
    end

    it "raises ArgumentError for an invalid trace ID without running the block" do
      ran = false
      expect do
        described_class.pin_generation_to("not-valid") { ran = true }
      end.to raise_error(ArgumentError, /Invalid trace_id/)
      expect(ran).to be(false)
    end
  end

  describe ".generate_trace_id" do
    it "falls back to a random trace ID when none is pinned" do
      expect(described_class.generate_trace_id.bytesize).to eq(16)
    end
  end

  describe ".generate_span_id" do
    it "returns a random 8-byte span ID" do
      expect(described_class.generate_span_id.bytesize).to eq(8)
    end
  end
end
