# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::PromptCacheCoordinator do
  let(:prompt_data) do
    {
      "name" => "greeting",
      "version" => 1,
      "type" => "text",
      "prompt" => "Hello"
    }
  end

  let(:events) { [] }
  let(:emitter) do
    double("cache event emitter").tap do |emitter|
      allow(emitter).to receive(:emit_prompt_cache_event) do |event, payload = nil, &block|
        events << (payload || block.call).merge(event: event)
      end
    end
  end
  let(:fetch_prompt) do
    lambda do |name, version:, label:|
      prompt_data.merge("name" => name, "version" => version || 1, "label" => label)
    end
  end

  def build_coordinator(cache)
    described_class.new(cache: cache, event_emitter: emitter, fetch_prompt: fetch_prompt)
  end

  it "returns disabled and bypass statuses without writing cache" do
    disabled = build_coordinator(nil).get_prompt_result("greeting")
    bypass = build_coordinator(Langfuse::PromptCache.new(ttl: 60)).get_prompt_result("greeting", cache_ttl: 0)

    expect(disabled.cache_status).to eq(Langfuse::CacheStatus::DISABLED)
    expect(disabled.source).to eq(Langfuse::CacheSource::API)
    expect(bypass.cache_status).to eq(Langfuse::CacheStatus::BYPASS)
    expect(bypass.storage_key).to start_with("g0:")
  end

  it "tracks miss, write, and hit through the cache backend" do
    cache = Langfuse::PromptCache.new(ttl: 60)
    coordinator = build_coordinator(cache)

    miss = coordinator.get_prompt_result("greeting")
    hit = coordinator.get_prompt_result("greeting")

    expect(miss.cache_status).to eq(Langfuse::CacheStatus::MISS)
    expect(hit.cache_status).to eq(Langfuse::CacheStatus::HIT)
    expect(events.map { |event| event[:event] }).to include(:miss, :write, :hit)
    expect(coordinator.prompt_cache_stats).to include(backend: "memory", enabled: true)
  end

  it "invalidates exact, name, and global scopes using public cache keys" do
    cache = Langfuse::PromptCache.new(ttl: 60)
    coordinator = build_coordinator(cache)
    key = coordinator.invalidate_prompt_cache("greeting", label: "production")
    name_generation = coordinator.invalidate_prompt_cache_by_name("greeting")
    global_generation = coordinator.clear_prompt_cache

    expect(key.logical_key).to eq("greeting:production")
    expect(name_generation).to eq(1)
    expect(global_generation).to eq(1)
    expect(events.map { |event| event[:event] }).to include(:delete, :invalidate, :clear)
  end

  it "validates mutually exclusive version and label plus cache_ttl type" do
    coordinator = build_coordinator(Langfuse::PromptCache.new(ttl: 60))

    expect { coordinator.get_prompt_result("greeting", version: 1, label: "production") }
      .to raise_error(ArgumentError, "Cannot specify both version and label")
    expect { coordinator.get_prompt_result("greeting", cache_ttl: "60") }
      .to raise_error(ArgumentError, "cache_ttl must be a non-negative Integer")
    expect { coordinator.get_prompt_result("greeting", cache_ttl: -1) }
      .to raise_error(ArgumentError, "cache_ttl must be non-negative")
  end
end
