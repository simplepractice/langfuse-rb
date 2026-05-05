# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::PromptCacheCapabilities do
  describe "disabled cache" do
    subject(:capabilities) { described_class.new(nil) }

    it "reports disabled stats and no optional capabilities" do
      expect(capabilities.enabled?).to be false
      expect(capabilities.backend_name).to eq(Langfuse::CacheBackend::DISABLED)
      expect(capabilities.generated_storage_key?).to be false
      expect(capabilities.swr?).to be false
      expect(capabilities.distributed_lock?).to be false
      expect(capabilities.storage_key("prompt:production", name: "prompt")).to eq("prompt:production")
      expect(capabilities.stats).to include(backend: "disabled", enabled: false)
      expect(capabilities.validate!).to be true
      expect(capabilities.shutdown).to be_nil
    end
  end

  describe "memory cache" do
    subject(:capabilities) { described_class.new(cache) }

    let(:cache) { Langfuse::PromptCache.new(ttl: 60, stale_ttl: 30) }

    it "wraps generated-key cache operations" do
      key = capabilities.storage_key("greeting:production", name: "greeting")

      expect(capabilities.backend_name).to eq(Langfuse::CacheBackend::MEMORY)
      expect(capabilities.generated_storage_key?).to be true
      expect(capabilities.swr?).to be true
      expect(capabilities.distributed_lock?).to be false
      expect(key).to start_with("g0:")

      capabilities.set(key, { "name" => "greeting" }, ttl: 5)

      expect(capabilities.get(key)).to eq({ "name" => "greeting" })
      expect(capabilities.entry(key).data).to eq({ "name" => "greeting" })
      expect(capabilities.delete(key)).to be true
      expect(capabilities.invalidate_name("greeting")).to eq(1)
      expect(capabilities.clear_logically).to eq(1)
      expect(capabilities.stats).to include(backend: "memory", enabled: true, ttl: 60, max_size: 1000)
    end
  end

  describe "custom cache" do
    let(:custom_cache_class) do
      Class.new do
        attr_reader :shutdown_called

        def initialize
          @store = {}
          @shutdown_called = false
        end

        def get(key)
          @store[key]
        end

        def set(key, value, ttl: nil)
          @store[key] = { value: value, ttl: ttl }
        end

        def fetch_with_lock(key, ttl: nil)
          @store[key] ||= yield.merge("ttl" => ttl)
        end

        def stats
          { backend: "custom", enabled: true }
        end

        def validate! # rubocop:disable Naming/PredicateMethod
          true
        end

        def shutdown
          @shutdown_called = true
        end
      end
    end

    it "centralizes respond_to probing for custom backends" do
      stub_const("CustomPromptCache", custom_cache_class)
      cache = CustomPromptCache.new
      capabilities = described_class.new(cache)

      expect(capabilities.backend_name).to eq("CustomPromptCache")
      expect(capabilities.generated_storage_key?).to be false
      expect(capabilities.distributed_lock?).to be true
      expect(capabilities.fetch_with_lock("k", ttl: 7) { { "name" => "x" } }).to eq("name" => "x", "ttl" => 7)
      expect(capabilities.validate!).to be true

      capabilities.shutdown

      expect(cache.shutdown_called).to be true
    end
  end
end
