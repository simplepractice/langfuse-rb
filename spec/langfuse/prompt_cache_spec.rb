# frozen_string_literal: true

RSpec.describe Langfuse::PromptCache do
  let(:cache) { described_class.new(ttl: 2, max_size: 3) }
  let(:test_data) { { "id" => "123", "name" => "test", "prompt" => "Hello {{name}}" } }

  describe "CacheEntry" do
    describe "#fresh?" do
      it "returns true when current time is before fresh_until" do
        entry = described_class::CacheEntry.new("data", Time.now + 10, Time.now + 20)
        expect(entry.fresh?).to be true
      end

      it "returns false when current time is at or after fresh_until" do
        entry = described_class::CacheEntry.new("data", Time.now - 1, Time.now + 10)
        expect(entry.fresh?).to be false
      end
    end

    describe "#stale?" do
      it "returns true when current time is between fresh_until and stale_until" do
        entry = described_class::CacheEntry.new("data", Time.now - 1, Time.now + 10)
        expect(entry.stale?).to be true
      end

      it "returns false when entry is still fresh" do
        entry = described_class::CacheEntry.new("data", Time.now + 10, Time.now + 20)
        expect(entry.stale?).to be false
      end

      it "returns false when entry is expired" do
        entry = described_class::CacheEntry.new("data", Time.now - 10, Time.now - 1)
        expect(entry.stale?).to be false
      end
    end

    describe "#expired?" do
      it "returns true when current time is at or after stale_until" do
        entry = described_class::CacheEntry.new("data", Time.now - 10, Time.now - 1)
        expect(entry.expired?).to be true
      end

      it "returns false when entry is still fresh" do
        entry = described_class::CacheEntry.new("data", Time.now + 10, Time.now + 20)
        expect(entry.expired?).to be false
      end

      it "returns false when entry is stale but not expired" do
        entry = described_class::CacheEntry.new("data", Time.now - 1, Time.now + 10)
        expect(entry.expired?).to be false
      end
    end
  end

  describe "#initialize" do
    it "sets default TTL" do
      cache = described_class.new
      expect(cache.ttl).to eq(60)
    end

    it "sets custom TTL" do
      cache = described_class.new(ttl: 120)
      expect(cache.ttl).to eq(120)
    end

    it "sets default max_size" do
      cache = described_class.new
      expect(cache.max_size).to eq(1000)
    end

    it "sets custom max_size" do
      cache = described_class.new(max_size: 500)
      expect(cache.max_size).to eq(500)
    end

    context "with stale_ttl" do
      it "sets custom stale_ttl" do
        cache = described_class.new(stale_ttl: 300)
        expect(cache.stale_ttl).to eq(300)
      end

      it "defaults to 0 when not specified (SWR disabled)" do
        cache = described_class.new(ttl: 60)
        expect(cache.stale_ttl).to eq(0)
      end

      it "enables SWR when stale_ttl equals ttl" do
        cache = described_class.new(ttl: 60, stale_ttl: 60)
        expect(cache.swr_enabled?).to be true
      end

      it "enables SWR when stale_ttl is any positive number" do
        cache = described_class.new(ttl: 60, stale_ttl: 1)
        expect(cache.swr_enabled?).to be true
      end

      it "disables SWR when stale_ttl is 0" do
        cache = described_class.new(ttl: 60, stale_ttl: 0)
        expect(cache.swr_enabled?).to be false
      end

      it "disables SWR when stale_ttl is negative" do
        cache = described_class.new(ttl: 60, stale_ttl: -10)
        expect(cache.swr_enabled?).to be false
      end
    end

    context "with thread pool initialization (SWR enabled)" do
      it "enables SWR behavior when stale_ttl is greater than ttl" do
        cache = described_class.new(ttl: 60, stale_ttl: 120)
        expect(cache.swr_enabled?).to be true
        # Verify fetch_with_stale_while_revalidate is used (not fetch_with_lock)
        expect(cache).not_to receive(:fetch_with_lock)
        cache.fetch_with_stale_while_revalidate("test") { "value" }
      end

      it "enables SWR behavior when stale_ttl equals ttl" do
        cache = described_class.new(ttl: 60, stale_ttl: 60)
        expect(cache.swr_enabled?).to be true
        expect(cache).not_to receive(:fetch_with_lock)
        cache.fetch_with_stale_while_revalidate("test") { "value" }
      end

      it "enables SWR behavior for any positive stale_ttl value" do
        cache = described_class.new(ttl: 60, stale_ttl: 1)
        expect(cache.swr_enabled?).to be true
        expect(cache).not_to receive(:fetch_with_lock)
        cache.fetch_with_stale_while_revalidate("test") { "value" }
      end

      it "accepts custom refresh_threads parameter" do
        # Can't verify thread pool size directly, but can verify it doesn't error
        expect do
          described_class.new(ttl: 60, stale_ttl: 120, refresh_threads: 10)
        end.not_to raise_error
      end
    end

    context "with thread pool initialization (SWR disabled)" do
      it "raises ConfigurationError when stale_ttl is 0" do
        cache = described_class.new(ttl: 60, stale_ttl: 0)
        expect(cache.swr_enabled?).to be false
        expect do
          cache.fetch_with_stale_while_revalidate("test") { "value" }
        end.to raise_error(
          Langfuse::ConfigurationError,
          /fetch_with_stale_while_revalidate requires a positive stale_ttl/
        )
      end

      it "raises ConfigurationError when stale_ttl is negative" do
        cache = described_class.new(ttl: 60, stale_ttl: -10)
        expect(cache.swr_enabled?).to be false
        expect do
          cache.fetch_with_stale_while_revalidate("test") { "value" }
        end.to raise_error(
          Langfuse::ConfigurationError,
          /fetch_with_stale_while_revalidate requires a positive stale_ttl/
        )
      end

      it "raises ConfigurationError when stale_ttl is not provided" do
        cache = described_class.new(ttl: 60)
        expect(cache.swr_enabled?).to be false
        expect do
          cache.fetch_with_stale_while_revalidate("test") { "value" }
        end.to raise_error(
          Langfuse::ConfigurationError,
          /fetch_with_stale_while_revalidate requires a positive stale_ttl/
        )
      end

      it "raises ConfigurationError even when refresh_threads is provided" do
        cache = described_class.new(ttl: 60, refresh_threads: 20)
        expect(cache.swr_enabled?).to be false
        expect do
          cache.fetch_with_stale_while_revalidate("test") { "value" }
        end.to raise_error(
          Langfuse::ConfigurationError,
          /fetch_with_stale_while_revalidate requires a positive stale_ttl/
        )
      end
    end
  end

  describe "#get and #set" do
    it "stores and retrieves a value" do
      cache.set("key1", test_data)
      result = cache.get("key1")
      expect(result).to eq(test_data)
    end

    it "returns nil for non-existent key" do
      result = cache.get("nonexistent")
      expect(result).to be_nil
    end

    it "returns the value being set" do
      result = cache.set("key1", test_data)
      expect(result).to eq(test_data)
    end

    it "overwrites existing value" do
      cache.set("key1", { value: 1 })
      cache.set("key1", { value: 2 })
      expect(cache.get("key1")).to eq({ value: 2 })
    end
  end

  describe "#clear" do
    it "removes all entries" do
      cache.set("key1", test_data)
      cache.set("key2", test_data)
      cache.clear
      expect(cache.get("key1")).to be_nil
      expect(cache.get("key2")).to be_nil
    end

    it "resets size to zero" do
      cache.set("key1", test_data)
      cache.set("key2", test_data)
      cache.clear
      expect(cache.size).to eq(0)
    end
  end

  describe "TTL expiration" do
    it "returns nil for expired entries" do
      cache.set("key1", test_data)
      sleep(2.1)
      expect(cache.get("key1")).to be_nil
    end

    it "returns value before expiration" do
      cache.set("key1", test_data)
      sleep(1)
      expect(cache.get("key1")).to eq(test_data)
    end
  end

  describe "#cleanup_expired" do
    it "removes expired entries" do
      cache.set("key1", test_data)
      cache.set("key2", test_data)
      sleep(2.1)
      removed_count = cache.cleanup_expired
      expect(removed_count).to eq(2)
      expect(cache.size).to eq(0)
    end

    it "keeps non-expired entries" do
      cache.set("key1", test_data)
      sleep(1)
      cache.set("key2", test_data)
      sleep(1.1)
      cache.cleanup_expired
      expect(cache.get("key1")).to be_nil
      expect(cache.get("key2")).to eq(test_data)
    end

    it "returns count of removed entries" do
      cache.set("key1", test_data)
      cache.set("key2", test_data)
      sleep(2.1)
      expect(cache.cleanup_expired).to eq(2)
    end
  end

  describe "#size" do
    it "returns zero for empty cache" do
      expect(cache.size).to eq(0)
    end

    it "returns correct count" do
      cache.set("key1", test_data)
      cache.set("key2", test_data)
      expect(cache.size).to eq(2)
    end

    it "decreases after cleanup" do
      cache.set("key1", test_data)
      cache.set("key2", test_data)
      sleep(2.1)
      cache.cleanup_expired
      expect(cache.size).to eq(0)
    end
  end

  describe "#empty?" do
    it "returns true for empty cache" do
      expect(cache).to be_empty
    end

    it "returns false when cache has entries" do
      cache.set("key1", test_data)
      expect(cache).not_to be_empty
    end

    it "returns true after clearing" do
      cache.set("key1", test_data)
      cache.clear
      expect(cache).to be_empty
    end
  end

  describe "max_size eviction" do
    it "evicts oldest entry when at max size" do
      cache.set("key1", test_data)
      cache.set("key2", test_data)
      cache.set("key3", test_data)
      cache.set("key4", test_data) # Should evict key1

      expect(cache.size).to eq(3)
      expect(cache.get("key1")).to be_nil
      expect(cache.get("key2")).not_to be_nil
      expect(cache.get("key3")).not_to be_nil
      expect(cache.get("key4")).not_to be_nil
    end
  end

  describe ".build_key" do
    it "builds key from name only" do
      key = described_class.build_key("greeting")
      expect(key).to eq("greeting")
    end

    it "builds key with version" do
      key = described_class.build_key("greeting", version: 2)
      expect(key).to eq("greeting:v2")
    end

    it "builds key with label" do
      key = described_class.build_key("greeting", label: "production")
      expect(key).to eq("greeting:production")
    end

    it "builds key with version and ignores label when both provided" do
      key = described_class.build_key("greeting", version: 2, label: "production")
      expect(key).to eq("greeting:v2:production")
    end

    it "handles string names" do
      key = described_class.build_key(:greeting)
      expect(key).to eq("greeting")
    end
  end

  describe "thread safety" do
    it "handles concurrent access" do
      threads = 10.times.map do
        Thread.new do
          10.times do |i|
            cache.set("thread_key_#{i}", { value: i })
            cache.get("thread_key_#{i}")
          end
        end
      end

      threads.each(&:join)
      expect(cache.size).to be <= 3 # max_size is 3
    end
  end

  describe "#shutdown" do
    it "shuts down gracefully when SWR is enabled" do
      cache = described_class.new(ttl: 60, stale_ttl: 120)
      expect(cache.swr_enabled?).to be true

      expect { cache.shutdown }.not_to raise_error
    end

    it "does not raise an error when SWR is disabled" do
      cache = described_class.new(ttl: 60, stale_ttl: 0)
      expect(cache.swr_enabled?).to be false

      expect { cache.shutdown }.not_to raise_error
    end
  end
end
