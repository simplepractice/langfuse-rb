# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::RailsCacheAdapter do
  # Mock Rails.cache for testing
  let(:mock_cache) { double("Rails.cache") }

  before do
    # Stub Rails constant and cache
    rails_class = Class.new do
      def self.cache
        @cache ||= nil
      end

      class << self
        attr_writer :cache
      end
    end

    stub_const("Rails", rails_class)
    Rails.cache = mock_cache
  end

  describe "#initialize" do
    context "when Rails.cache is available" do
      it "creates an adapter with default TTL" do
        adapter = described_class.new
        expect(adapter.ttl).to eq(60)
        expect(adapter.namespace).to eq("langfuse")
      end

      it "creates an adapter with custom TTL" do
        adapter = described_class.new(ttl: 120)
        expect(adapter.ttl).to eq(120)
      end

      it "creates an adapter with custom namespace" do
        adapter = described_class.new(namespace: "my_app")
        expect(adapter.namespace).to eq("my_app")
      end

      context "when stale TTL is provided (SWR enabled)" do
        it "creates an adapter with custom stale TTL" do
          adapter = described_class.new(stale_ttl: 300)
          expect(adapter.stale_ttl).to eq(300)
        end

        it "initializes thread pool with default refresh_threads (5)" do
          expect(Concurrent::CachedThreadPool).to receive(:new)
            .with(
              max_threads: 5,
              min_threads: 2,
              max_queue: 50,
              fallback_policy: :discard
            ).and_call_original

          adapter = described_class.new(stale_ttl: 300)

          # Verify thread pool is initialized and can accept work
          expect(adapter.thread_pool).to be_a(Concurrent::CachedThreadPool)
          expect(adapter.thread_pool.running?).to be true
          expect(adapter.thread_pool.shuttingdown?).to be false
        end

        it "initializes thread pool with custom refresh_threads parameter" do
          expect(Concurrent::CachedThreadPool).to receive(:new)
            .with(
              max_threads: 3,
              min_threads: 2,
              max_queue: 50,
              fallback_policy: :discard
            ).and_call_original

          adapter = described_class.new(stale_ttl: 300, refresh_threads: 3)

          # Verify thread pool is initialized and can accept work
          expect(adapter.thread_pool).to be_a(Concurrent::CachedThreadPool)
          expect(adapter.thread_pool.running?).to be true
          expect(adapter.thread_pool.shuttingdown?).to be false
        end
      end

      context "when stale TTL is not provided (SWR disabled)" do
        it "does not initialize thread pool when stale_ttl is not provided" do
          adapter = described_class.new(ttl: 60)
          expect(adapter.thread_pool).to be_nil
        end

        it "ignores refresh_threads when stale_ttl is not provided" do
          # refresh_threads should have no effect without stale_ttl
          adapter = described_class.new(ttl: 60, refresh_threads: 20)
          expect(adapter.thread_pool).to be_nil
        end
      end

      context "with logger parameter" do
        it "uses provided logger" do
          custom_logger = Logger.new($stdout)
          adapter = described_class.new(logger: custom_logger)
          expect(adapter.logger).to eq(custom_logger)
        end

        it "creates default stdout logger when no logger provided and Rails.logger not available" do
          allow(Rails).to receive(:respond_to?).and_return(true)
          allow(Rails).to receive(:respond_to?).with(:logger).and_return(false)
          adapter = described_class.new
          expect(adapter.logger).to be_a(Logger)
        end

        it "uses Rails.logger as default when Rails is available" do
          rails_logger = Logger.new($stdout)
          allow(Rails).to receive_messages(respond_to?: true, logger: rails_logger)
          adapter = described_class.new
          expect(adapter.logger).to eq(rails_logger)
        end

        it "creates stdout logger when Rails.logger returns nil" do
          allow(Rails).to receive_messages(respond_to?: true, logger: nil)
          adapter = described_class.new
          expect(adapter.logger).to be_a(Logger)
        end
      end
    end

    context "when Rails.cache is not available" do
      before do
        hide_const("Rails")
      end

      it "raises ConfigurationError" do
        expect do
          described_class.new
        end.to raise_error(
          Langfuse::ConfigurationError,
          /Rails.cache is not available/
        )
      end
    end

    context "when Rails is defined but cache is not available" do
      before do
        rails_without_cache = Class.new
        stub_const("Rails", rails_without_cache)
      end

      it "raises ConfigurationError" do
        expect do
          described_class.new
        end.to raise_error(
          Langfuse::ConfigurationError,
          /Rails.cache is not available/
        )
      end
    end
  end

  describe "#get" do
    let(:adapter) { described_class.new(ttl: 60) }

    it "reads from Rails.cache with namespaced key" do
      expect(mock_cache).to receive(:read).with("langfuse:greeting:v1").and_return({ "name" => "greeting" })

      result = adapter.get("greeting:v1")
      expect(result).to eq({ "name" => "greeting" })
    end

    it "returns nil when key not found" do
      expect(mock_cache).to receive(:read).with("langfuse:missing").and_return(nil)

      result = adapter.get("missing")
      expect(result).to be_nil
    end

    it "uses custom namespace" do
      custom_adapter = described_class.new(namespace: "custom")
      expect(mock_cache).to receive(:read).with("custom:key").and_return("value")

      custom_adapter.get("key")
    end
  end

  describe "#set" do
    let(:adapter) { described_class.new(ttl: 120) }

    it "writes to Rails.cache with namespaced key and TTL" do
      data = { "name" => "greeting", "prompt" => "Hello!" }
      expect(mock_cache).to receive(:write).with(
        "langfuse:greeting:v1",
        data,
        expires_in: 120
      ).and_return(true)

      result = adapter.set("greeting:v1", data)
      expect(result).to eq(data)
    end

    it "returns the cached value" do
      expect(mock_cache).to receive(:write).and_return(true)

      result = adapter.set("key", "value")
      expect(result).to eq("value")
    end

    it "uses custom namespace and TTL" do
      custom_adapter = described_class.new(ttl: 300, namespace: "custom")
      expect(mock_cache).to receive(:write).with(
        "custom:key",
        "value",
        expires_in: 300
      ).and_return(true)

      custom_adapter.set("key", "value")
    end
  end

  describe "#clear" do
    let(:adapter) { described_class.new }

    it "deletes all keys matching namespace pattern" do
      expect(mock_cache).to receive(:delete_matched).with("langfuse:*")

      adapter.clear
    end

    it "uses custom namespace for pattern" do
      custom_adapter = described_class.new(namespace: "custom")
      expect(mock_cache).to receive(:delete_matched).with("custom:*")

      custom_adapter.clear
    end
  end

  describe "#size" do
    let(:adapter) { described_class.new }

    it "returns nil (not supported by Rails.cache)" do
      expect(adapter.size).to be_nil
    end
  end

  describe "#empty?" do
    let(:adapter) { described_class.new }

    it "returns false (not supported by Rails.cache)" do
      expect(adapter.empty?).to be false
    end
  end

  describe ".build_key" do
    it "delegates to PromptCache.build_key" do
      expect(Langfuse::PromptCache).to receive(:build_key).with(
        "greeting",
        version: 1,
        label: nil
      ).and_return("greeting:v1")

      key = described_class.build_key("greeting", version: 1)
      expect(key).to eq("greeting:v1")
    end

    it "builds key with name only" do
      key = described_class.build_key("greeting")
      expect(key).to eq("greeting")
    end

    it "builds key with name and version" do
      key = described_class.build_key("greeting", version: 2)
      expect(key).to eq("greeting:v2")
    end

    it "builds key with name and label" do
      key = described_class.build_key("greeting", label: "production")
      expect(key).to eq("greeting:production")
    end

    it "builds key with all parameters" do
      key = described_class.build_key("greeting", version: 3, label: "staging")
      expect(key).to eq("greeting:v3:staging")
    end
  end

  describe "integration with cache interface" do
    let(:adapter) { described_class.new(ttl: 60) }

    it "implements the same interface as PromptCache" do
      # Should respond to all public methods that PromptCache has
      expect(adapter).to respond_to(:get)
      expect(adapter).to respond_to(:set)
      expect(adapter).to respond_to(:clear)
      expect(adapter).to respond_to(:size)
      expect(adapter).to respond_to(:empty?)
      expect(described_class).to respond_to(:build_key)
    end

    it "can be used interchangeably with PromptCache" do
      # Simulate the pattern used in ApiClient
      cache = adapter
      cache_key = described_class.build_key("greeting", version: 1)

      # Mock Rails.cache operations
      expect(mock_cache).to receive(:read).with("langfuse:greeting:v1").and_return(nil)
      expect(mock_cache).to receive(:write).with(
        "langfuse:greeting:v1",
        { "data" => "test" },
        expires_in: 60
      ).and_return(true)

      # Check cache (miss)
      cached = cache.get(cache_key)
      expect(cached).to be_nil

      # Set cache
      cache.set(cache_key, { "data" => "test" })

      # Mock successful read
      expect(mock_cache).to receive(:read).with("langfuse:greeting:v1").and_return({ "data" => "test" })

      # Check cache (hit)
      cached = cache.get(cache_key)
      expect(cached).to eq({ "data" => "test" })
    end
  end

  describe "#fetch_with_lock" do
    let(:adapter) { described_class.new(ttl: 120, lock_timeout: 5) }
    let(:cache_key) { "greeting:v1" }
    let(:lock_key) { "langfuse:greeting:v1:lock" }
    let(:namespaced_key) { "langfuse:greeting:v1" }

    context "when cache hit" do
      it "returns cached value without acquiring lock" do
        expect(mock_cache).to receive(:read).with(namespaced_key).and_return({ "cached" => "data" })

        result = adapter.fetch_with_lock(cache_key) do
          raise "Block should not be called on cache hit!"
        end

        expect(result).to eq({ "cached" => "data" })
      end

      it "does not execute the block" do
        expect(mock_cache).to receive(:read).with(namespaced_key).and_return({ "cached" => "data" })

        block_executed = false
        adapter.fetch_with_lock(cache_key) do
          block_executed = true
        end

        expect(block_executed).to be false
      end
    end

    context "when cache miss and lock acquired" do
      it "executes block and populates cache" do
        # Cache miss
        expect(mock_cache).to receive(:read).with(namespaced_key).and_return(nil)

        # Lock acquisition succeeds
        expect(mock_cache).to receive(:write).with(
          lock_key,
          true,
          unless_exist: true,
          expires_in: 5
        ).and_return(true)

        # Set cache with result
        expect(mock_cache).to receive(:write).with(
          namespaced_key,
          { "fresh" => "data" },
          expires_in: 120
        ).and_return(true)

        # Release lock
        expect(mock_cache).to receive(:delete).with(lock_key)

        result = adapter.fetch_with_lock(cache_key) do
          { "fresh" => "data" }
        end

        expect(result).to eq({ "fresh" => "data" })
      end

      it "releases lock even if block raises error" do
        expect(mock_cache).to receive(:read).with(namespaced_key).and_return(nil)
        expect(mock_cache).to receive(:write).with(
          lock_key,
          true,
          unless_exist: true,
          expires_in: 5
        ).and_return(true)

        # Lock should still be released even if block fails
        expect(mock_cache).to receive(:delete).with(lock_key)

        expect do
          adapter.fetch_with_lock(cache_key) do
            raise StandardError, "Simulated API error"
          end
        end.to raise_error(StandardError, "Simulated API error")
      end
    end

    context "when cache miss and lock NOT acquired (someone else has it)" do
      it "waits and returns cached value if available" do
        # Cache miss initially
        expect(mock_cache).to receive(:read).with(namespaced_key).and_return(nil)

        # Lock acquisition fails (someone else has it)
        expect(mock_cache).to receive(:write).with(
          lock_key,
          true,
          unless_exist: true,
          expires_in: 5
        ).and_return(false)

        # Wait with exponential backoff (3 retries)
        # First retry (50ms) - still empty
        expect(mock_cache).to receive(:read).with(namespaced_key).and_return(nil)

        # Second retry (100ms) - populated!
        expect(mock_cache).to receive(:read).with(namespaced_key).and_return({ "populated" => "by lock holder" })

        result = adapter.fetch_with_lock(cache_key) do
          raise "Block should not execute - cache was populated by lock holder"
        end

        expect(result).to eq({ "populated" => "by lock holder" })
      end

      it "falls back to fetching if cache still empty after waiting" do
        # Cache miss initially
        expect(mock_cache).to receive(:read).with(namespaced_key).and_return(nil)

        # Lock acquisition fails
        expect(mock_cache).to receive(:write).with(
          lock_key,
          true,
          unless_exist: true,
          expires_in: 5
        ).and_return(false)

        # Wait with 3 retries - all return nil (cache still empty)
        expect(mock_cache).to receive(:read).with(namespaced_key).and_return(nil).exactly(3).times

        # Block should execute as fallback
        result = adapter.fetch_with_lock(cache_key) do
          { "fallback" => "fetch" }
        end

        expect(result).to eq({ "fallback" => "fetch" })
      end

      it "uses exponential backoff when waiting" do
        expect(mock_cache).to receive(:read).with(namespaced_key).and_return(nil)
        expect(mock_cache).to receive(:write).and_return(false) # Lock not acquired

        # All retries return nil
        expect(mock_cache).to receive(:read).with(namespaced_key).and_return(nil).exactly(3).times

        start_time = Time.now

        adapter.fetch_with_lock(cache_key) do
          { "data" => "test" }
        end

        elapsed = Time.now - start_time

        # Should sleep for 0.05 + 0.1 + 0.2 = 0.35 seconds
        # Allow some tolerance for test execution time
        expect(elapsed).to be >= 0.30 # At least 300ms
        expect(elapsed).to be < 0.50  # Less than 500ms (with buffer)
      end
    end

    context "with custom lock timeout" do
      let(:custom_adapter) { described_class.new(ttl: 60, lock_timeout: 15) }

      it "uses custom lock timeout when acquiring lock" do
        expect(mock_cache).to receive(:read).with(namespaced_key).and_return(nil)
        expect(mock_cache).to receive(:write).with(
          lock_key,
          true,
          unless_exist: true,
          expires_in: 15 # Custom timeout
        ).and_return(true)

        expect(mock_cache).to receive(:write).with(namespaced_key, anything, expires_in: 60).and_return(true)
        expect(mock_cache).to receive(:delete).with(lock_key)

        custom_adapter.fetch_with_lock(cache_key) do
          { "data" => "test" }
        end
      end
    end
  end

  describe "stampede protection behavior" do
    let(:adapter) { described_class.new(ttl: 60) }

    it "responds to fetch_with_lock" do
      expect(adapter).to respond_to(:fetch_with_lock)
    end

    it "both PromptCache and RailsCacheAdapter support fetch_with_lock for stampede protection" do
      memory_cache = Langfuse::PromptCache.new(ttl: 60)
      rails_cache = adapter

      # Both caches now support fetch_with_lock via StaleWhileRevalidate module
      expect(memory_cache).to respond_to(:fetch_with_lock)
      expect(rails_cache).to respond_to(:fetch_with_lock)
    end
  end

  describe "#fetch_with_stale_while_revalidate" do
    let(:ttl) { 60 }
    let(:stale_ttl) { 120 }
    let(:refresh_threads) { 2 }
    let(:adapter_with_swr) { described_class.new(ttl:, stale_ttl:, refresh_threads:) }
    let(:adapter_without_swr) { described_class.new(ttl:) }

    before do
      allow(mock_cache).to receive_messages(read: nil, write: true, delete: true, delete_matched: true)
    end

    context "when SWR is disabled" do
      it "falls back to fetch_with_lock" do
        cache_key = "test_key"
        new_data = "new_value"
        expect(adapter_without_swr).to receive(:fetch_with_lock).with(cache_key)
        adapter_without_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
      end
    end

    context "with fresh cache entry" do
      it "returns cached data immediately" do
        cache_key = "test_key"
        fresh_data = "fresh_value"
        new_data = "new_value"

        fresh_entry = Langfuse::PromptCache::CacheEntry.new(
          fresh_data,
          Time.now + 30,
          Time.now + 150
        )

        # Mock Rails.cache to return the fresh entry
        allow(mock_cache).to receive(:read)
          .with("langfuse:#{cache_key}")
          .and_return(fresh_entry)

        result = adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
        expect(result).to eq(fresh_data)
      end

      it "does not trigger background refresh" do
        cache_key = "test_key"
        fresh_data = "fresh_value"
        new_data = "new_value"

        fresh_entry = Langfuse::PromptCache::CacheEntry.new(
          fresh_data,
          Time.now + 30,
          Time.now + 150
        )

        # Mock Rails.cache to return the fresh entry
        allow(mock_cache).to receive(:read)
          .with("langfuse:#{cache_key}")
          .and_return(fresh_entry)

        # Verify thread pool is not used
        expect(adapter_with_swr.thread_pool).not_to receive(:post)

        adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
      end
    end

    context "with stale entry (revalidate state)" do
      it "returns stale data immediately" do
        cache_key = "test_key"
        stale_data = "stale_value"
        new_data = "new_value"
        stale_entry = Langfuse::PromptCache::CacheEntry.new(
          stale_data,
          Time.now - 30, # Expired
          Time.now + 90  # Still within grace period
        )

        # Mock Rails.cache to return the stale entry
        allow(mock_cache).to receive(:read)
          .with("langfuse:#{cache_key}")
          .and_return(stale_entry)

        result = adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }

        expect(result).to eq(stale_data)
      end

      it "schedules background refresh" do
        cache_key = "test_key"
        stale_data = "stale_value"
        new_data = "new_value"
        refresh_lock_key = "langfuse:#{cache_key}:refreshing"

        stale_entry = Langfuse::PromptCache::CacheEntry.new(
          stale_data,
          Time.now - 30, # Expired
          Time.now + 90  # Still within grace period
        )

        # Mock Rails.cache to return the stale entry
        allow(mock_cache).to receive(:read)
          .with("langfuse:#{cache_key}")
          .and_return(stale_entry)

        # Mock cache write operations during refresh
        allow(mock_cache).to receive(:write)
          .with("langfuse:#{cache_key}", new_data, expires_in: 180)
          .and_return(true)

        # Mock lock release
        allow(mock_cache).to receive(:delete)
          .with(refresh_lock_key)

        # Verify thread pool is used
        expect(adapter_with_swr.thread_pool).to receive(:post).and_yield

        adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
      end
    end

    context "with expired entry (past stale period)" do
      it "fetches fresh data synchronously" do
        cache_key = "test_key"
        stale_data = "stale_value"
        new_data = "new_value"
        expired_entry = Langfuse::PromptCache::CacheEntry.new(
          stale_data,
          Time.now - 150, # Expired
          Time.now - 30   # Past grace period
        )

        # Mock Rails.cache to return the expired entry
        allow(mock_cache).to receive(:read)
          .with("langfuse:#{cache_key}")
          .and_return(expired_entry)

        # Mock cache write for the new data
        allow(mock_cache).to receive(:write)
          .with("langfuse:#{cache_key}", new_data, expires_in: 180)
          .and_return(true)

        result = adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
        expect(result).to eq(new_data)
      end

      it "does not schedule background refresh" do
        cache_key = "test_key"
        stale_data = "stale_value"
        new_data = "new_value"

        expired_entry = Langfuse::PromptCache::CacheEntry.new(
          stale_data,
          Time.now - 150, # Expired
          Time.now - 30   # Past grace period
        )

        # Mock Rails.cache to return the expired entry
        allow(mock_cache).to receive(:read)
          .with("langfuse:#{cache_key}")
          .and_return(expired_entry)

        # Mock cache write for the new data
        allow(mock_cache).to receive(:write)
          .with("langfuse:#{cache_key}", new_data, expires_in: 180)
          .and_return(true)

        # Verify thread pool is not used
        expect(adapter_with_swr.thread_pool).not_to receive(:post)

        adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }
      end
    end

    context "with cache miss" do
      it "fetches fresh data synchronously" do
        cache_key = "test_key"
        new_data = "new_value"

        # Mock Rails.cache to return nil (cache miss)
        allow(mock_cache).to receive(:read)
          .with("langfuse:#{cache_key}")
          .and_return(nil)

        # Mock cache write for the new data
        allow(mock_cache).to receive(:write)
          .with("langfuse:#{cache_key}", new_data, expires_in: 180)
          .and_return(true)

        # Verify thread pool is not used
        expect(adapter_with_swr.thread_pool).not_to receive(:post)

        result = adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { new_data }

        expect(result).to eq(new_data)
      end
    end
  end

  describe "#schedule_refresh" do
    let(:ttl) { 60 }
    let(:stale_ttl) { 120 }
    let(:refresh_threads) { 2 }
    let(:adapter_with_swr) { described_class.new(ttl: ttl, stale_ttl: stale_ttl, refresh_threads: refresh_threads) }

    before do
      allow(mock_cache).to receive_messages(read: nil, write: true, delete: true, delete_matched: true)
    end

    context "when refresh lock is acquired" do
      it "schedules refresh in thread pool" do
        cache_key = "test_key"
        refresh_lock_key = "langfuse:#{cache_key}:refreshing"
        refreshed_value = "refreshed_value"

        # Mock lock acquisition succeeds
        allow(mock_cache).to receive(:write)
          .with(refresh_lock_key, true, unless_exist: true, expires_in: 60)
          .and_return(true)

        # Mock lock release
        allow(mock_cache).to receive(:delete)
          .with(refresh_lock_key)

        # Mock thread pool to execute immediately for testing
        allow(adapter_with_swr.thread_pool).to receive(:post).and_yield

        # Verify cache is written with CacheEntry (note: double namespacing due to implementation)
        # We need to allow the lock write first, then expect the cache write
        cache_write_called = false
        # TODO: Fix this spec, there are better ways to implement this scenario
        allow(mock_cache).to receive(:write) do |key, value, options|
          if key == "langfuse:#{cache_key}"
            # Cache write with CacheEntry
            expect(value).to be_a(Langfuse::PromptCache::CacheEntry)
            expect(value.data).to eq(refreshed_value)
            expect(options[:expires_in]).to eq(180)
            cache_write_called = true
          end
          true
        end

        adapter_with_swr.send(:schedule_refresh, cache_key) { refreshed_value }
        expect(cache_write_called).to be true
      end

      it "releases the refresh lock after completion" do
        cache_key = "test_key"
        refresh_lock_key = "langfuse:#{cache_key}:refreshing"

        # Mock lock acquisition succeeds
        allow(mock_cache).to receive(:write)
          .with(refresh_lock_key, true, unless_exist: true, expires_in: 60)
          .and_return(true)

        # Mock cache write
        allow(mock_cache).to receive(:write)
          .with("langfuse:#{cache_key}", anything, expires_in: 180)
          .and_return(true)

        # Mock thread pool to execute immediately
        allow(adapter_with_swr.thread_pool).to receive(:post).and_yield

        # Verify lock is released
        expect(mock_cache).to receive(:delete)
          .with(refresh_lock_key)

        adapter_with_swr.send(:schedule_refresh, cache_key) { "refreshed_value" }
      end

      it "logs error and releases lock when refresh block raises error" do
        cache_key = "test_key"
        refresh_lock_key = "langfuse:#{cache_key}:refreshing"
        mock_logger = instance_double(Logger)

        adapter_with_logger = described_class.new(
          ttl: ttl,
          stale_ttl: stale_ttl,
          refresh_threads: refresh_threads,
          logger: mock_logger
        )

        # Mock lock acquisition succeeds
        allow(mock_cache).to receive(:write)
          .with(refresh_lock_key, true, unless_exist: true, expires_in: 60)
          .and_return(true)

        # Mock thread pool to execute immediately
        allow(adapter_with_logger.thread_pool).to receive(:post).and_yield

        expect(mock_logger).to receive(:error)
          .with(/Langfuse cache refresh failed for key 'test_key': RuntimeError - test error/)

        # Verify lock is released even on error
        expect(mock_cache).to receive(:delete)
          .with(refresh_lock_key)

        # Error should be caught and logged, not raised
        expect do
          adapter_with_logger.send(:schedule_refresh, cache_key) { raise "test error" }
        end.not_to raise_error
      end

      it "logs error with correct exception class and message" do
        cache_key = "greeting:1"
        refresh_lock_key = "langfuse:#{cache_key}:refreshing"
        mock_logger = instance_double(Logger)

        adapter_with_logger = described_class.new(
          ttl: ttl,
          stale_ttl: stale_ttl,
          refresh_threads: refresh_threads,
          logger: mock_logger
        )

        # Mock lock acquisition succeeds
        allow(mock_cache).to receive(:write)
          .with(refresh_lock_key, true, unless_exist: true, expires_in: 60)
          .and_return(true)

        # Mock thread pool to execute immediately
        allow(adapter_with_logger.thread_pool).to receive(:post).and_yield

        expect(mock_logger).to receive(:error)
          .with("Langfuse cache refresh failed for key 'greeting:1': ArgumentError - Invalid prompt data")

        # Verify lock is released even on error
        expect(mock_cache).to receive(:delete)
          .with(refresh_lock_key)

        # Custom exception type
        adapter_with_logger.send(:schedule_refresh, cache_key) do
          raise ArgumentError, "Invalid prompt data"
        end
      end
    end

    context "when refresh lock is not acquired" do
      it "does not schedule refresh" do
        cache_key = "test_key"
        refresh_lock_key = "langfuse:#{cache_key}:refreshing"

        # Mock lock acquisition fails
        allow(mock_cache).to receive(:write)
          .with(refresh_lock_key, true, unless_exist: true, expires_in: 60)
          .and_return(false)

        expect(adapter_with_swr.thread_pool).not_to receive(:post)
        adapter_with_swr.send(:schedule_refresh, cache_key) { "refreshed_value" }
      end
    end
  end

  describe "cache entry behavior" do
    let(:ttl) { 60 }
    let(:stale_ttl) { 120 }
    let(:refresh_threads) { 2 }
    let(:adapter_with_swr) { described_class.new(ttl: ttl, stale_ttl: stale_ttl, refresh_threads: refresh_threads) }

    context "when reading from cache" do
      it "returns CacheEntry objects with correct data" do
        cache_key = "test_key"
        namespaced_key = "langfuse:#{cache_key}"
        fresh_until_time = Time.now + 30
        stale_until_time = Time.now + 150

        # Create a CacheEntry that would be stored in Rails.cache
        cache_entry = Langfuse::PromptCache::CacheEntry.new(
          "test_value",
          fresh_until_time,
          stale_until_time
        )

        allow(mock_cache).to receive(:read)
          .with(namespaced_key)
          .and_return(cache_entry)

        result = adapter_with_swr.get(cache_key)

        expect(result).to be_a(Langfuse::PromptCache::CacheEntry)
        expect(result.data).to eq("test_value")
        expect(result.fresh_until).to eq(fresh_until_time)
        expect(result.stale_until).to eq(stale_until_time)
      end

      it "returns nil when cache is empty" do
        cache_key = "test_key"
        namespaced_key = "langfuse:#{cache_key}"

        allow(mock_cache).to receive(:read)
          .with(namespaced_key)
          .and_return(nil)

        result = adapter_with_swr.get(cache_key)
        expect(result).to be_nil
      end
    end

    context "when writing to cache" do
      it "regular set stores raw values, not CacheEntry objects" do
        cache_key = "test_key"
        value = "test_value"
        namespaced_key = "langfuse:#{cache_key}"

        # Regular set() stores the value directly, not wrapped in CacheEntry
        expect(mock_cache).to receive(:write) do |key, stored_value, options|
          expect(key).to eq(namespaced_key)
          expect(stored_value).to eq(value)
          expect(options[:expires_in]).to eq(ttl)
          true
        end

        result = adapter_with_swr.set(cache_key, value)
        expect(result).to eq(value)
      end

      it "SWR operations store CacheEntry objects with metadata" do
        cache_key = "test_key"
        value = "test_value"
        total_ttl = ttl + stale_ttl

        freeze_time = Time.now
        allow(Time).to receive(:now).and_return(freeze_time)

        # Mock cache miss to trigger fetch_and_cache
        allow(mock_cache).to receive(:read)
          .with("langfuse:#{cache_key}")
          .and_return(nil)

        # SWR operations use set_cache_entry which wraps in CacheEntry
        # Note: There's double namespacing due to set_cache_entry calling set(namespaced_key(...))
        expect(mock_cache).to receive(:write) do |key, entry, options|
          expect(key).to eq("langfuse:#{cache_key}")
          expect(entry).to be_a(Langfuse::PromptCache::CacheEntry)
          expect(entry.data).to eq(value)
          expect(entry.fresh_until).to be_within(1).of(freeze_time + ttl)
          expect(entry.stale_until).to be_within(1).of(freeze_time + total_ttl)
          expect(options[:expires_in]).to eq(total_ttl)
          true
        end

        result = adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { value }
        expect(result).to eq(value)
      end
    end
  end

  describe "refresh lock behavior" do
    let(:ttl) { 60 }
    let(:stale_ttl) { 120 }
    let(:refresh_threads) { 2 }
    let(:adapter_with_swr) { described_class.new(ttl: ttl, stale_ttl: stale_ttl, refresh_threads: refresh_threads) }

    it "uses Rails.cache to acquire locks atomically" do
      cache_key = "test_key"
      refresh_lock_key = "langfuse:#{cache_key}:refreshing"

      # Simulate stale entry to trigger refresh
      stale_entry = Langfuse::PromptCache::CacheEntry.new(
        "stale_data",
        Time.now - 30, # Expired
        Time.now + 90  # Still within grace period
      )

      allow(mock_cache).to receive(:read)
        .with("langfuse:#{cache_key}")
        .and_return(stale_entry)

      # Mock thread pool to execute immediately
      allow(adapter_with_swr.thread_pool).to receive(:post).and_yield

      # Mock lock release
      allow(mock_cache).to receive(:delete)
        .with(refresh_lock_key)

      # Mock cache write (double-namespaced due to implementation)
      allow(mock_cache).to receive(:write)
        .with("langfuse:#{cache_key}", anything, expires_in: 180)
        .and_return(true)

      # Verify lock acquisition is attempted with correct parameters
      expect(mock_cache).to receive(:write)
        .with(refresh_lock_key, true, unless_exist: true, expires_in: 60)
        .and_return(true)

      adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { "new_data" }
    end

    it "prevents duplicate refreshes when lock is not available" do
      cache_key = "test_key"
      refresh_lock_key = "langfuse:#{cache_key}:refreshing"

      # Lock acquisition fails (already held by another process)
      allow(mock_cache).to receive(:write)
        .with(refresh_lock_key, true, unless_exist: true, expires_in: 60)
        .and_return(false)

      # Simulate stale entry
      stale_entry = Langfuse::PromptCache::CacheEntry.new(
        "stale_data",
        Time.now - 30,
        Time.now + 90
      )

      allow(mock_cache).to receive(:read)
        .with("langfuse:#{cache_key}")
        .and_return(stale_entry)

      # Thread pool should not be used since lock was not acquired
      expect(adapter_with_swr.thread_pool).not_to receive(:post)

      result = adapter_with_swr.fetch_with_stale_while_revalidate(cache_key) { "new_data" }
      expect(result).to eq("stale_data")
    end
  end

  describe "#shutdown" do
    let(:ttl) { 60 }
    let(:stale_ttl) { 120 }
    let(:refresh_threads) { 2 }

    before do
      allow(mock_cache).to receive_messages(read: nil, write: true, delete: true, delete_matched: true)
    end

    it "shuts down the thread pool gracefully" do
      adapter = described_class.new(ttl: ttl, stale_ttl: stale_ttl, refresh_threads: refresh_threads)
      thread_pool = adapter.thread_pool
      expect(thread_pool).to receive(:shutdown).once
      expect(thread_pool).to receive(:wait_for_termination).with(5).once

      adapter.shutdown
    end

    context "when no thread pool exists" do
      it "does not raise an error" do
        adapter = described_class.new(ttl: ttl)
        expect { adapter.shutdown }.not_to raise_error
      end
    end
  end
end
