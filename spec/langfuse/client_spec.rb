# frozen_string_literal: true

RSpec.describe Langfuse::Client do
  let(:valid_config) do
    Langfuse::Config.new do |config|
      config.public_key = "pk_test_123"
      config.secret_key = "sk_test_456"
      config.base_url = "https://cloud.langfuse.com"
    end
  end

  describe "#initialize" do
    it "creates a client with valid config" do
      client = described_class.new(valid_config)
      expect(client).to be_a(described_class)
    end

    it "sets the config" do
      client = described_class.new(valid_config)
      expect(client.config).to eq(valid_config)
    end

    it "creates an api_client" do
      client = described_class.new(valid_config)
      expect(client.api_client).to be_a(Langfuse::ApiClient)
    end

    it "validates configuration on initialization" do
      invalid_config = Langfuse::Config.new
      expect do
        described_class.new(invalid_config)
      end.to raise_error(Langfuse::ConfigurationError)
    end

    context "with caching enabled" do
      let(:config_with_cache) do
        Langfuse::Config.new do |config|
          config.public_key = "pk_test_123"
          config.secret_key = "sk_test_456"
          config.base_url = "https://cloud.langfuse.com"
          config.cache_ttl = 60
          config.cache_max_size = 100
        end
      end

      it "creates api_client with cache" do
        client = described_class.new(config_with_cache)
        expect(client.api_client.cache).to be_a(Langfuse::PromptCache)
      end

      it "configures cache with correct TTL" do
        client = described_class.new(config_with_cache)
        expect(client.api_client.cache.ttl).to eq(60)
      end

      it "configures cache with correct max_size" do
        client = described_class.new(config_with_cache)
        expect(client.api_client.cache.max_size).to eq(100)
      end
    end

    context "with caching disabled" do
      let(:config_without_cache) do
        Langfuse::Config.new do |config|
          config.public_key = "pk_test_123"
          config.secret_key = "sk_test_456"
          config.base_url = "https://cloud.langfuse.com"
          config.cache_ttl = 0
        end
      end

      it "creates api_client without cache" do
        client = described_class.new(config_without_cache)
        expect(client.api_client.cache).to be_nil
      end
    end

    context "with Rails.cache backend" do
      let(:config_with_rails_cache) do
        Langfuse::Config.new do |config|
          config.public_key = "pk_test_123"
          config.secret_key = "sk_test_456"
          config.base_url = "https://cloud.langfuse.com"
          config.cache_ttl = 120
          config.cache_backend = :rails
        end
      end

      let(:mock_rails_cache) { double("Rails.cache") }

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
        Rails.cache = mock_rails_cache
      end

      it "creates api_client with RailsCacheAdapter" do
        client = described_class.new(config_with_rails_cache)
        expect(client.api_client.cache).to be_a(Langfuse::RailsCacheAdapter)
      end

      it "configures Rails cache adapter with correct TTL" do
        client = described_class.new(config_with_rails_cache)
        expect(client.api_client.cache.ttl).to eq(120)
      end

      it "ignores cache_max_size for Rails backend" do
        # Rails.cache doesn't use max_size, so it should create adapter without error
        config_with_rails_cache.cache_max_size = 500
        expect do
          described_class.new(config_with_rails_cache)
        end.not_to raise_error
      end

      it "passes logger from config to RailsCacheAdapter" do
        custom_logger = Logger.new($stdout)
        config_with_rails_cache.logger = custom_logger
        client = described_class.new(config_with_rails_cache)
        expect(client.api_client.cache.logger).to eq(custom_logger)
      end

      it "configures RailsCacheAdapter with stale-while-revalidate settings" do
        config_with_rails_cache.cache_stale_while_revalidate = true
        config_with_rails_cache.cache_stale_ttl = 300
        config_with_rails_cache.cache_refresh_threads = 3
        config_with_rails_cache.cache_lock_timeout = 15

        client = described_class.new(config_with_rails_cache)
        adapter = client.api_client.cache

        expect(adapter.stale_ttl).to eq(300)
        expect(adapter.lock_timeout).to eq(15)
        expect(adapter.thread_pool).to be_a(Concurrent::CachedThreadPool)
      end

      it "configures RailsCacheAdapter without SWR when disabled" do
        config_with_rails_cache.cache_stale_while_revalidate = false
        client = described_class.new(config_with_rails_cache)
        adapter = client.api_client.cache

        # When SWR disabled, stale_ttl defaults to 0 (no stale period, immediate expiration)
        expect(adapter.stale_ttl).to eq(0)
        expect(adapter.thread_pool).to be_nil # Thread pool not initialized when stale_ttl <= ttl
      end
    end

    context "with invalid cache backend" do
      let(:config_invalid_backend) do
        Langfuse::Config.new do |config|
          config.public_key = "pk_test_123"
          config.secret_key = "sk_test_456"
          config.base_url = "https://cloud.langfuse.com"
          config.cache_ttl = 60
          config.cache_backend = :invalid
        end
      end

      it "raises ConfigurationError during validation" do
        expect do
          described_class.new(config_invalid_backend)
        end.to raise_error(Langfuse::ConfigurationError, /cache_backend must be one of/)
      end
    end

    context "with :indefinite stale_ttl" do
      it "normalizes :indefinite to INDEFINITE_SECONDS via normalized_stale_ttl method" do
        config = Langfuse::Config.new do |c|
          c.public_key = "pk_test_123"
          c.secret_key = "sk_test_456"
          c.cache_stale_ttl = :indefinite
        end

        expect(config.normalized_stale_ttl).to eq(Langfuse::Config::INDEFINITE_SECONDS)
      end

      it "passes normalized stale_ttl to cache instances" do
        config = Langfuse::Config.new do |c|
          c.public_key = "pk_test_123"
          c.secret_key = "sk_test_456"
          c.cache_ttl = 60
          c.cache_stale_ttl = :indefinite
        end

        client = described_class.new(config)
        cache = client.api_client.cache

        expect(cache.stale_ttl).to eq(Langfuse::Config::INDEFINITE_SECONDS)
      end

      it "normalizes :indefinite when set via cache_stale_while_revalidate" do
        config = Langfuse::Config.new do |c|
          c.public_key = "pk_test_123"
          c.secret_key = "sk_test_456"
          c.cache_ttl = 60
          c.cache_stale_while_revalidate = true
          c.cache_stale_ttl = :indefinite
        end

        expect(config.normalized_stale_ttl).to eq(Langfuse::Config::INDEFINITE_SECONDS)
      end
    end
  end

  describe "#get_prompt" do
    let(:client) { described_class.new(valid_config) }
    let(:base_url) { valid_config.base_url }

    context "with text prompt" do
      let(:text_prompt_response) do
        {
          "id" => "prompt-123",
          "name" => "greeting",
          "version" => 1,
          "type" => "text",
          "prompt" => "Hello {{name}}!",
          "labels" => ["production"],
          "tags" => ["greetings"],
          "config" => {}
        }
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
          .to_return(
            status: 200,
            body: text_prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns a TextPromptClient" do
        result = client.get_prompt("greeting")
        expect(result).to be_a(Langfuse::TextPromptClient)
      end

      it "returns client with correct prompt data" do
        result = client.get_prompt("greeting")
        expect(result.name).to eq("greeting")
        expect(result.version).to eq(1)
        expect(result.prompt).to eq("Hello {{name}}!")
      end
    end

    context "with chat prompt" do
      let(:chat_prompt_response) do
        {
          "id" => "prompt-456",
          "name" => "chat-assistant",
          "version" => 2,
          "type" => "chat",
          "prompt" => [
            { "role" => "system", "content" => "You are {{role}}" },
            { "role" => "user", "content" => "Hello!" }
          ],
          "labels" => ["production"],
          "tags" => ["chat"],
          "config" => {}
        }
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/chat-assistant")
          .to_return(
            status: 200,
            body: chat_prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns a ChatPromptClient" do
        result = client.get_prompt("chat-assistant")
        expect(result).to be_a(Langfuse::ChatPromptClient)
      end

      it "returns client with correct prompt data" do
        result = client.get_prompt("chat-assistant")
        expect(result.name).to eq("chat-assistant")
        expect(result.version).to eq(2)
        expect(result.prompt).to be_an(Array)
      end
    end

    context "with unknown prompt type" do
      let(:unknown_type_response) do
        {
          "id" => "prompt-789",
          "name" => "unknown",
          "version" => 1,
          "type" => "unknown",
          "prompt" => "Some prompt",
          "labels" => [],
          "tags" => [],
          "config" => {}
        }
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/unknown")
          .to_return(
            status: 200,
            body: unknown_type_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ApiError" do
        expect do
          client.get_prompt("unknown")
        end.to raise_error(Langfuse::ApiError, "Unknown prompt type: unknown")
      end
    end

    context "with version parameter" do
      let(:text_prompt_response) do
        {
          "id" => "prompt-123",
          "name" => "greeting",
          "version" => 2,
          "type" => "text",
          "prompt" => "Hello {{name}}!",
          "labels" => [],
          "tags" => [],
          "config" => {}
        }
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
          .with(query: { version: "2" })
          .to_return(
            status: 200,
            body: text_prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "passes version to api_client" do
        result = client.get_prompt("greeting", version: 2)
        expect(result.version).to eq(2)
      end

      it "makes request with version parameter" do
        client.get_prompt("greeting", version: 2)
        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
            .with(query: { version: "2" })
        ).to have_been_made.once
      end
    end

    context "with label parameter" do
      let(:text_prompt_response) do
        {
          "id" => "prompt-123",
          "name" => "greeting",
          "version" => 1,
          "type" => "text",
          "prompt" => "Hello {{name}}!",
          "labels" => ["production"],
          "tags" => [],
          "config" => {}
        }
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
          .with(query: { label: "production" })
          .to_return(
            status: 200,
            body: text_prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "passes label to api_client" do
        result = client.get_prompt("greeting", label: "production")
        expect(result.labels).to include("production")
      end

      it "makes request with label parameter" do
        client.get_prompt("greeting", label: "production")
        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
            .with(query: { label: "production" })
        ).to have_been_made.once
      end
    end

    context "when prompt is not found" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/missing")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "raises NotFoundError" do
        expect do
          client.get_prompt("missing")
        end.to raise_error(Langfuse::NotFoundError)
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect do
          client.get_prompt("greeting")
        end.to raise_error(Langfuse::UnauthorizedError)
      end
    end

    context "when API returns an error" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
          .to_return(
            status: 500,
            body: { message: "Internal server error" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ApiError" do
        expect do
          client.get_prompt("greeting")
        end.to raise_error(Langfuse::ApiError, /API request failed/)
      end
    end

    context "with caching enabled" do
      let(:config_with_cache) do
        Langfuse::Config.new do |config|
          config.public_key = "pk_test_123"
          config.secret_key = "sk_test_456"
          config.base_url = "https://cloud.langfuse.com"
          config.cache_ttl = 60
        end
      end

      let(:cached_client) { described_class.new(config_with_cache) }

      let(:text_prompt_response) do
        {
          "id" => "prompt-123",
          "name" => "greeting",
          "version" => 1,
          "type" => "text",
          "prompt" => "Hello {{name}}!",
          "labels" => [],
          "tags" => [],
          "config" => {}
        }
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
          .to_return(
            status: 200,
            body: text_prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "caches prompt responses" do
        # First call - hits API
        first_result = cached_client.get_prompt("greeting")

        # Second call - should use cache
        second_result = cached_client.get_prompt("greeting")

        # Verify same data returned
        expect(second_result.name).to eq(first_result.name)
        expect(second_result.version).to eq(first_result.version)

        # Verify API was only called once
        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
        ).to have_been_made.once
      end
    end

    context "with fallback support" do
      context "when prompt not found (404)" do
        before do
          stub_request(:get, "#{base_url}/api/public/v2/prompts/missing")
            .to_return(status: 404, body: { message: "Not found" }.to_json)
        end

        it "returns fallback text prompt when provided" do
          result = client.get_prompt("missing", fallback: "Hello {{name}}!", type: :text)
          expect(result).to be_a(Langfuse::TextPromptClient)
          expect(result.prompt).to eq("Hello {{name}}!")
        end

        it "sets fallback prompt metadata correctly" do
          result = client.get_prompt("missing", fallback: "Hello!", type: :text)
          expect(result.name).to eq("missing")
          expect(result.version).to eq(0)
          expect(result.tags).to include("fallback")
        end

        it "raises error when no fallback provided" do
          expect do
            client.get_prompt("missing")
          end.to raise_error(Langfuse::NotFoundError)
        end
      end

      context "when authentication fails (401)" do
        before do
          stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
            .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
        end

        it "returns fallback text prompt when provided" do
          result = client.get_prompt("greeting", fallback: "Hello {{name}}!", type: :text)
          expect(result).to be_a(Langfuse::TextPromptClient)
          expect(result.prompt).to eq("Hello {{name}}!")
        end

        it "raises error when no fallback provided" do
          expect do
            client.get_prompt("greeting")
          end.to raise_error(Langfuse::UnauthorizedError)
        end
      end

      context "when API error occurs (500)" do
        before do
          stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
            .to_return(
              status: 500,
              body: { message: "Internal server error" }.to_json,
              headers: { "Content-Type" => "application/json" }
            )
        end

        it "returns fallback text prompt when provided" do
          result = client.get_prompt("greeting", fallback: "Hello {{name}}!", type: :text)
          expect(result).to be_a(Langfuse::TextPromptClient)
          expect(result.prompt).to eq("Hello {{name}}!")
        end

        it "raises error when no fallback provided" do
          expect do
            client.get_prompt("greeting")
          end.to raise_error(Langfuse::ApiError)
        end
      end

      context "with chat prompt fallback" do
        let(:fallback_messages) do
          [
            { "role" => "system", "content" => "You are a {{role}} assistant" }
          ]
        end

        before do
          stub_request(:get, "#{base_url}/api/public/v2/prompts/chat-bot")
            .to_return(status: 404, body: { message: "Not found" }.to_json)
        end

        it "returns fallback chat prompt when provided" do
          result = client.get_prompt("chat-bot", fallback: fallback_messages, type: :chat)
          expect(result).to be_a(Langfuse::ChatPromptClient)
          expect(result.prompt).to eq(fallback_messages)
        end

        it "sets fallback chat prompt metadata correctly" do
          result = client.get_prompt("chat-bot", fallback: fallback_messages, type: :chat)
          expect(result.name).to eq("chat-bot")
          expect(result.version).to eq(0)
          expect(result.tags).to include("fallback")
        end
      end

      context "with fallback validation" do
        it "requires type parameter when fallback is provided" do
          expect do
            client.get_prompt("greeting", fallback: "Hello!")
          end.to raise_error(ArgumentError, /type parameter is required/)
        end

        it "accepts :text type" do
          stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
            .to_return(status: 404, body: { message: "Not found" }.to_json)

          result = client.get_prompt("greeting", fallback: "Hello!", type: :text)
          expect(result).to be_a(Langfuse::TextPromptClient)
        end

        it "accepts :chat type" do
          stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
            .to_return(status: 404, body: { message: "Not found" }.to_json)

          result = client.get_prompt("greeting", fallback: [], type: :chat)
          expect(result).to be_a(Langfuse::ChatPromptClient)
        end

        it "rejects invalid type" do
          stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
            .to_return(status: 404, body: { message: "Not found" }.to_json)

          expect do
            client.get_prompt("greeting", fallback: "Hello!", type: :invalid)
          end.to raise_error(ArgumentError, /Invalid type.*Must be :text or :chat/)
        end
      end

      context "with logging" do
        it "logs warning when using fallback" do
          stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
            .to_return(status: 404, body: { message: "Not found" }.to_json)

          expect(client.config.logger).to receive(:warn)
            .with(/Langfuse API error for prompt 'greeting'.*Using fallback/)

          client.get_prompt("greeting", fallback: "Hello!", type: :text)
        end
      end
    end
  end

  describe "#compile_prompt" do
    let(:client) { described_class.new(valid_config) }
    let(:base_url) { valid_config.base_url }

    context "with text prompt" do
      let(:text_prompt_response) do
        {
          "id" => "prompt-123",
          "name" => "greeting",
          "version" => 1,
          "type" => "text",
          "prompt" => "Hello {{name}}!",
          "labels" => [],
          "tags" => [],
          "config" => {}
        }
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
          .to_return(
            status: 200,
            body: text_prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "fetches and compiles prompt in one call" do
        result = client.compile_prompt("greeting", variables: { name: "Alice" })
        expect(result).to eq("Hello Alice!")
      end

      it "returns compiled string for text prompts" do
        result = client.compile_prompt("greeting", variables: { name: "Bob" })
        expect(result).to be_a(String)
        expect(result).to eq("Hello Bob!")
      end

      it "works without variables" do
        result = client.compile_prompt("greeting", variables: {})
        expect(result).to eq("Hello {{name}}!")
      end
    end

    context "with chat prompt" do
      let(:chat_prompt_response) do
        {
          "id" => "prompt-456",
          "name" => "support-bot",
          "version" => 1,
          "type" => "chat",
          "prompt" => [
            { "role" => "system", "content" => "You are a {{role}} agent" }
          ],
          "labels" => [],
          "tags" => [],
          "config" => {}
        }
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/support-bot")
          .to_return(
            status: 200,
            body: chat_prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "fetches and compiles chat prompt" do
        result = client.compile_prompt("support-bot", variables: { role: "support" })
        expect(result).to be_an(Array)
        expect(result.first[:content]).to eq("You are a support agent")
      end

      it "returns array of messages for chat prompts" do
        result = client.compile_prompt("support-bot", variables: { role: "billing" })
        expect(result).to be_an(Array)
        expect(result).to all(be_a(Hash))
        expect(result.first).to have_key(:role)
        expect(result.first).to have_key(:content)
      end
    end

    context "with version parameter" do
      let(:text_prompt_response) do
        {
          "id" => "prompt-123",
          "name" => "greeting",
          "version" => 2,
          "type" => "text",
          "prompt" => "Hi {{name}}!",
          "labels" => [],
          "tags" => [],
          "config" => {}
        }
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
          .with(query: { version: "2" })
          .to_return(
            status: 200,
            body: text_prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "fetches specific version and compiles" do
        result = client.compile_prompt("greeting", variables: { name: "Charlie" }, version: 2)
        expect(result).to eq("Hi Charlie!")
      end
    end

    context "with label parameter" do
      let(:text_prompt_response) do
        {
          "id" => "prompt-123",
          "name" => "greeting",
          "version" => 1,
          "type" => "text",
          "prompt" => "Greetings {{name}}!",
          "labels" => ["production"],
          "tags" => [],
          "config" => {}
        }
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
          .with(query: { label: "production" })
          .to_return(
            status: 200,
            body: text_prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "fetches labeled version and compiles" do
        result = client.compile_prompt("greeting", variables: { name: "Dave" }, label: "production")
        expect(result).to eq("Greetings Dave!")
      end
    end

    context "when prompt is not found" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/missing")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "raises NotFoundError" do
        expect do
          client.compile_prompt("missing", variables: { name: "Test" })
        end.to raise_error(Langfuse::NotFoundError)
      end
    end

    context "with fallback support" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/missing")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "compiles fallback text prompt when API fails" do
        result = client.compile_prompt(
          "missing",
          variables: { name: "Alice" },
          fallback: "Hello {{name}}!",
          type: :text
        )
        expect(result).to eq("Hello Alice!")
      end

      it "compiles fallback chat prompt when API fails" do
        fallback_messages = [
          { "role" => "system", "content" => "You are a {{role}} assistant" }
        ]
        result = client.compile_prompt(
          "missing",
          variables: { role: "helpful" },
          fallback: fallback_messages,
          type: :chat
        )
        expect(result).to be_an(Array)
        expect(result.first[:content]).to eq("You are a helpful assistant")
      end

      it "works with version and label parameters" do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
          .with(query: { version: "2" })
          .to_return(status: 404, body: { message: "Not found" }.to_json)

        result = client.compile_prompt(
          "greeting",
          variables: { name: "Bob" },
          version: 2,
          fallback: "Hi {{name}}!",
          type: :text
        )
        expect(result).to eq("Hi Bob!")
      end

      it "requires type parameter with fallback" do
        expect do
          client.compile_prompt(
            "missing",
            variables: { name: "Test" },
            fallback: "Hello!"
          )
        end.to raise_error(ArgumentError, /type parameter is required/)
      end
    end
  end

  describe "#list_prompts" do
    let(:client) { described_class.new(valid_config) }
    let(:base_url) { valid_config.base_url }

    let(:prompts_list_response) do
      {
        "data" => [
          { "name" => "greeting", "version" => 1, "type" => "text" },
          { "name" => "conversation", "version" => 2, "type" => "chat" },
          { "name" => "rag-pipeline", "version" => 1, "type" => "text" }
        ],
        "meta" => { "totalItems" => 3, "page" => 1 }
      }
    end

    context "without pagination" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts")
          .to_return(
            status: 200,
            body: prompts_list_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns list of prompts" do
        result = client.list_prompts

        expect(result).to be_an(Array)
        expect(result.size).to eq(3)
      end

      it "returns prompt metadata" do
        result = client.list_prompts

        expect(result.first).to have_key("name")
        expect(result.first).to have_key("version")
        expect(result.first).to have_key("type")
      end

      it "makes request without query parameters" do
        client.list_prompts

        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts")
            .with(query: {})
        ).to have_been_made.once
      end
    end

    context "with pagination parameters" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts")
          .with(query: { page: "2", limit: "10" })
          .to_return(
            status: 200,
            body: prompts_list_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "passes pagination parameters to API" do
        client.list_prompts(page: 2, limit: 10)

        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts")
            .with(query: { page: "2", limit: "10" })
        ).to have_been_made.once
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts")
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect do
          client.list_prompts
        end.to raise_error(Langfuse::UnauthorizedError)
      end
    end

    context "when API error occurs" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts")
          .to_return(
            status: 500,
            body: { message: "Internal server error" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ApiError" do
        expect do
          client.list_prompts
        end.to raise_error(Langfuse::ApiError, /API request failed/)
      end
    end

    context "when no prompts exist" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts")
          .to_return(
            status: 200,
            body: { "data" => [], "meta" => {} }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns empty array" do
        result = client.list_prompts

        expect(result).to be_an(Array)
        expect(result).to be_empty
      end
    end
  end

  describe "#create_prompt" do
    let(:client) { described_class.new(valid_config) }
    let(:base_url) { valid_config.base_url }

    context "with text prompt" do
      let(:created_text_response) do
        {
          "id" => "prompt-new",
          "name" => "greeting",
          "version" => 1,
          "type" => "text",
          "prompt" => "Hello {{name}}!",
          "labels" => ["staging"],
          "tags" => ["greeting"],
          "config" => { "model" => "gpt-4o" }
        }
      end

      before do
        stub_request(:post, "#{base_url}/api/public/v2/prompts")
          .to_return(
            status: 201,
            body: created_text_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns TextPromptClient" do
        result = client.create_prompt(
          name: "greeting",
          prompt: "Hello {{name}}!",
          type: :text
        )
        expect(result).to be_a(Langfuse::TextPromptClient)
      end

      it "sets prompt data correctly" do
        result = client.create_prompt(
          name: "greeting",
          prompt: "Hello {{name}}!",
          type: :text,
          labels: ["staging"],
          config: { model: "gpt-4o" }
        )
        expect(result.name).to eq("greeting")
        expect(result.prompt).to eq("Hello {{name}}!")
        expect(result.version).to eq(1)
        expect(result.labels).to include("staging")
      end

      it "compiles the created prompt" do
        result = client.create_prompt(
          name: "greeting",
          prompt: "Hello {{name}}!",
          type: :text
        )
        expect(result.compile(name: "Alice")).to eq("Hello Alice!")
      end
    end

    context "with chat prompt" do
      let(:created_chat_response) do
        {
          "id" => "prompt-chat",
          "name" => "assistant",
          "version" => 1,
          "type" => "chat",
          "prompt" => [
            { "role" => "system", "content" => "You are a {{role}} assistant" }
          ],
          "labels" => [],
          "tags" => [],
          "config" => {}
        }
      end

      before do
        stub_request(:post, "#{base_url}/api/public/v2/prompts")
          .to_return(
            status: 201,
            body: created_chat_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns ChatPromptClient" do
        result = client.create_prompt(
          name: "assistant",
          prompt: [{ role: :system, content: "You are a {{role}} assistant" }],
          type: :chat
        )
        expect(result).to be_a(Langfuse::ChatPromptClient)
      end

      it "normalizes symbol keys to string keys" do
        client.create_prompt(
          name: "assistant",
          prompt: [{ role: :system, content: "You are helpful" }],
          type: :chat
        )
        expect(
          a_request(:post, "#{base_url}/api/public/v2/prompts")
            .with(body: hash_including(
              "prompt" => [{ "role" => "system", "content" => "You are helpful" }]
            ))
        ).to have_been_made.once
      end

      it "compiles the created chat prompt" do
        result = client.create_prompt(
          name: "assistant",
          prompt: [{ role: :system, content: "You are a {{role}} assistant" }],
          type: :chat
        )
        compiled = result.compile(role: "helpful")
        expect(compiled.first[:content]).to eq("You are a helpful assistant")
      end
    end

    context "with all optional parameters" do
      let(:created_response) do
        {
          "id" => "prompt-full",
          "name" => "full-prompt",
          "version" => 1,
          "type" => "text",
          "prompt" => "Hello!",
          "labels" => ["production"],
          "tags" => %w[greeting v1],
          "config" => { "temperature" => 0.7 }
        }
      end

      before do
        stub_request(:post, "#{base_url}/api/public/v2/prompts")
          .to_return(
            status: 201,
            body: created_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "passes all parameters to api_client" do
        client.create_prompt(
          name: "full-prompt",
          prompt: "Hello!",
          type: :text,
          config: { temperature: 0.7 },
          labels: ["production"],
          tags: %w[greeting v1],
          commit_message: "Initial version"
        )

        expect(
          a_request(:post, "#{base_url}/api/public/v2/prompts")
            .with(body: hash_including(
              "name" => "full-prompt",
              "prompt" => "Hello!",
              "type" => "text",
              "config" => { "temperature" => 0.7 },
              "labels" => ["production"],
              "tags" => %w[greeting v1],
              "commitMessage" => "Initial version"
            ))
        ).to have_been_made.once
      end
    end

    context "with validation errors" do
      it "raises ArgumentError for invalid type" do
        expect do
          client.create_prompt(name: "test", prompt: "Hello", type: :invalid)
        end.to raise_error(ArgumentError, /Invalid type.*Must be :text or :chat/)
      end

      it "raises ArgumentError when text prompt is not a String" do
        expect do
          client.create_prompt(name: "test", prompt: [], type: :text)
        end.to raise_error(ArgumentError, "Text prompt must be a String")
      end

      it "raises ArgumentError when chat prompt is not an Array" do
        expect do
          client.create_prompt(name: "test", prompt: "Hello", type: :chat)
        end.to raise_error(ArgumentError, "Chat prompt must be an Array")
      end
    end
  end

  describe "#update_prompt" do
    let(:client) { described_class.new(valid_config) }
    let(:base_url) { valid_config.base_url }

    context "with text prompt" do
      let(:updated_response) do
        {
          "id" => "prompt-123",
          "name" => "greeting",
          "version" => 2,
          "type" => "text",
          "prompt" => "Hello {{name}}!",
          "labels" => ["production"],
          "tags" => [],
          "config" => {}
        }
      end

      before do
        stub_request(:patch, "#{base_url}/api/public/v2/prompts/greeting/versions/2")
          .to_return(
            status: 200,
            body: updated_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns TextPromptClient" do
        result = client.update_prompt(name: "greeting", version: 2, labels: ["production"])
        expect(result).to be_a(Langfuse::TextPromptClient)
      end

      it "returns prompt with updated labels" do
        result = client.update_prompt(name: "greeting", version: 2, labels: ["production"])
        expect(result.labels).to include("production")
      end
    end

    context "with chat prompt" do
      let(:updated_chat_response) do
        {
          "id" => "prompt-456",
          "name" => "assistant",
          "version" => 1,
          "type" => "chat",
          "prompt" => [{ "role" => "system", "content" => "You are helpful" }],
          "labels" => ["production"],
          "tags" => [],
          "config" => {}
        }
      end

      before do
        stub_request(:patch, "#{base_url}/api/public/v2/prompts/assistant/versions/1")
          .to_return(
            status: 200,
            body: updated_chat_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns ChatPromptClient" do
        result = client.update_prompt(name: "assistant", version: 1, labels: ["production"])
        expect(result).to be_a(Langfuse::ChatPromptClient)
      end
    end

    context "with invalid labels argument" do
      it "raises ArgumentError when labels is not an array" do
        expect do
          client.update_prompt(name: "greeting", version: 1, labels: "production")
        end.to raise_error(ArgumentError, "labels must be an array")
      end
    end
  end

  describe "#trace_url" do
    let(:client) { described_class.new(valid_config) }

    it "generates trace URL with default base_url" do
      trace_id = "a" * 32 # 32 hex characters
      url = client.trace_url(trace_id)

      expect(url).to eq("https://cloud.langfuse.com/traces/#{trace_id}")
    end

    it "generates trace URL with custom base_url" do
      custom_config = Langfuse::Config.new do |config|
        config.public_key = "pk_test_123"
        config.secret_key = "sk_test_456"
        config.base_url = "https://custom.langfuse.com"
      end
      custom_client = described_class.new(custom_config)
      trace_id = "b" * 32

      url = custom_client.trace_url(trace_id)

      expect(url).to eq("https://custom.langfuse.com/traces/#{trace_id}")
    end

    it "handles trace IDs of any length" do
      trace_id = "abc123def456"
      url = client.trace_url(trace_id)

      expect(url).to eq("https://cloud.langfuse.com/traces/#{trace_id}")
    end
  end

  describe "#create_score" do
    let(:client) { described_class.new(valid_config) }

    before do
      stub_request(:post, "https://cloud.langfuse.com/api/public/ingestion")
        .to_return(status: 200, body: "", headers: {})
    end

    it "delegates to score_client" do
      score_client = client.instance_variable_get(:@score_client)
      expect(score_client).to receive(:create).with(
        name: "quality",
        value: 0.85,
        trace_id: "abc123",
        observation_id: nil,
        comment: nil,
        metadata: nil,
        data_type: :numeric
      )

      client.create_score(name: "quality", value: 0.85, trace_id: "abc123")
    end

    it "passes all parameters to score_client" do
      score_client = client.instance_variable_get(:@score_client)
      expect(score_client).to receive(:create).with(
        name: "quality",
        value: 0.85,
        trace_id: "abc123",
        observation_id: "def456",
        comment: "High quality",
        metadata: { source: "manual" },
        data_type: :boolean
      )

      client.create_score(
        name: "quality",
        value: 0.85,
        trace_id: "abc123",
        observation_id: "def456",
        comment: "High quality",
        metadata: { source: "manual" },
        data_type: :boolean
      )
    end
  end

  describe "#score_active_observation" do
    let(:client) { described_class.new(valid_config) }
    let(:tracer) { OpenTelemetry.tracer_provider.tracer("test") }
    let(:span) { tracer.start_span("test-span") }

    before do
      stub_request(:post, "https://cloud.langfuse.com/api/public/ingestion")
        .to_return(status: 200, body: "", headers: {})
    end

    it "delegates to score_client" do
      score_client = client.instance_variable_get(:@score_client)
      expect(score_client).to receive(:score_active_observation).with(
        name: "accuracy",
        value: 0.92,
        comment: nil,
        metadata: nil,
        data_type: :numeric
      )

      OpenTelemetry::Context.with_current(
        OpenTelemetry::Trace.context_with_span(span)
      ) do
        client.score_active_observation(name: "accuracy", value: 0.92)
      end
    end
  end

  describe "#score_active_trace" do
    let(:client) { described_class.new(valid_config) }
    let(:tracer) { OpenTelemetry.tracer_provider.tracer("test") }
    let(:span) { tracer.start_span("test-span") }

    before do
      stub_request(:post, "https://cloud.langfuse.com/api/public/ingestion")
        .to_return(status: 200, body: "", headers: {})
    end

    it "delegates to score_client" do
      score_client = client.instance_variable_get(:@score_client)
      expect(score_client).to receive(:score_active_trace).with(
        name: "overall_quality",
        value: 5,
        comment: nil,
        metadata: nil,
        data_type: :numeric
      )

      OpenTelemetry::Context.with_current(
        OpenTelemetry::Trace.context_with_span(span)
      ) do
        client.score_active_trace(name: "overall_quality", value: 5)
      end
    end
  end

  describe "#flush_scores" do
    let(:client) { described_class.new(valid_config) }

    it "delegates to score_client" do
      score_client = client.instance_variable_get(:@score_client)
      expect(score_client).to receive(:flush)

      client.flush_scores
    end
  end

  describe "#shutdown" do
    let(:client) { described_class.new(valid_config) }

    it "delegates to score_client shutdown" do
      score_client = client.instance_variable_get(:@score_client)
      expect(score_client).to receive(:shutdown)

      client.shutdown
    end

    context "when cache supports shutdown" do
      let(:config_with_cache) do
        Langfuse::Config.new do |config|
          config.public_key = "pk_test"
          config.secret_key = "sk_test"
          config.cache_ttl = 60
          config.cache_stale_ttl = 120
        end
      end
      let(:client_with_cache) { described_class.new(config_with_cache) }

      it "calls shutdown on the cache" do
        cache = client_with_cache.api_client.cache
        expect(cache).to receive(:shutdown)

        client_with_cache.shutdown
      end
    end

    context "when cache does not support shutdown" do
      let(:config_without_swr) do
        Langfuse::Config.new do |config|
          config.public_key = "pk_test"
          config.secret_key = "sk_test"
          config.cache_ttl = 60
          config.cache_stale_ttl = 0
        end
      end
      let(:client_without_swr) { described_class.new(config_without_swr) }

      it "does not raise an error" do
        expect { client_without_swr.shutdown }.not_to raise_error
      end
    end

    context "when cache is nil" do
      let(:config_no_cache) do
        Langfuse::Config.new do |config|
          config.public_key = "pk_test"
          config.secret_key = "sk_test"
          config.cache_ttl = 0
        end
      end
      let(:client_no_cache) { described_class.new(config_no_cache) }

      it "does not raise an error" do
        expect { client_no_cache.shutdown }.not_to raise_error
      end
    end
  end

  describe "#create_dataset" do
    let(:client) { described_class.new(valid_config) }
    let(:base_url) { valid_config.base_url }
    let(:created_dataset) do
      {
        "id" => "ds-new",
        "name" => "new-dataset",
        "description" => "A test dataset"
      }
    end

    before do
      stub_request(:post, "#{base_url}/api/public/v2/datasets")
        .to_return(
          status: 201,
          body: created_dataset.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns a DatasetClient" do
      result = client.create_dataset(name: "new-dataset")
      expect(result).to be_a(Langfuse::DatasetClient)
    end

    it "sets dataset data correctly" do
      result = client.create_dataset(name: "new-dataset", description: "A test dataset")
      expect(result.id).to eq("ds-new")
      expect(result.name).to eq("new-dataset")
      expect(result.description).to eq("A test dataset")
    end
  end

  describe "#get_dataset" do
    let(:client) { described_class.new(valid_config) }
    let(:base_url) { valid_config.base_url }
    let(:dataset_response) do
      {
        "id" => "ds-123",
        "name" => "evaluation-qa",
        "description" => "QA dataset"
      }
    end

    context "with successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/datasets/evaluation-qa")
          .to_return(
            status: 200,
            body: dataset_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns a DatasetClient" do
        result = client.get_dataset("evaluation-qa")
        expect(result).to be_a(Langfuse::DatasetClient)
      end

      it "returns client with correct dataset data" do
        result = client.get_dataset("evaluation-qa")
        expect(result.id).to eq("ds-123")
        expect(result.name).to eq("evaluation-qa")
      end
    end

    context "when not found" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/datasets/missing")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { client.get_dataset("missing") }.to raise_error(Langfuse::NotFoundError)
      end
    end
  end

  describe "#list_datasets" do
    let(:client) { described_class.new(valid_config) }
    let(:base_url) { valid_config.base_url }
    let(:datasets_response) do
      {
        "data" => [
          { "id" => "ds-1", "name" => "dataset-1" },
          { "id" => "ds-2", "name" => "dataset-2" }
        ],
        "meta" => {}
      }
    end

    before do
      stub_request(:get, "#{base_url}/api/public/v2/datasets")
        .to_return(
          status: 200,
          body: datasets_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns array of dataset data" do
      result = client.list_datasets
      expect(result).to be_an(Array)
      expect(result.size).to eq(2)
    end

    it "returns raw hash data (not wrapped)" do
      result = client.list_datasets
      expect(result.first).to be_a(Hash)
      expect(result.first["name"]).to eq("dataset-1")
    end
  end

  describe "#create_dataset_item" do
    let(:client) { described_class.new(valid_config) }
    let(:base_url) { valid_config.base_url }
    let(:created_item) do
      {
        "id" => "item-new",
        "datasetId" => "ds-123",
        "input" => { "question" => "What is 2+2?" },
        "expectedOutput" => { "answer" => "4" }
      }
    end

    before do
      stub_request(:post, "#{base_url}/api/public/dataset-items")
        .to_return(
          status: 201,
          body: created_item.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns a DatasetItemClient" do
      result = client.create_dataset_item(dataset_name: "my-dataset")
      expect(result).to be_a(Langfuse::DatasetItemClient)
    end

    it "sets item data correctly" do
      result = client.create_dataset_item(
        dataset_name: "my-dataset",
        input: { "question" => "What is 2+2?" },
        expected_output: { "answer" => "4" }
      )
      expect(result.id).to eq("item-new")
      expect(result.input).to eq({ "question" => "What is 2+2?" })
      expect(result.expected_output).to eq({ "answer" => "4" })
    end
  end

  describe "#get_dataset_item" do
    let(:client) { described_class.new(valid_config) }
    let(:base_url) { valid_config.base_url }
    let(:item_response) do
      {
        "id" => "item-123",
        "datasetId" => "ds-456",
        "input" => { "q" => "test" }
      }
    end

    context "with successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/dataset-items/item-123")
          .to_return(
            status: 200,
            body: item_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns a DatasetItemClient" do
        result = client.get_dataset_item("item-123")
        expect(result).to be_a(Langfuse::DatasetItemClient)
      end

      it "returns client with correct item data" do
        result = client.get_dataset_item("item-123")
        expect(result.id).to eq("item-123")
        expect(result.dataset_id).to eq("ds-456")
      end
    end

    context "when not found" do
      before do
        stub_request(:get, "#{base_url}/api/public/dataset-items/missing")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { client.get_dataset_item("missing") }.to raise_error(Langfuse::NotFoundError)
      end
    end
  end

  describe "#list_dataset_items" do
    let(:client) { described_class.new(valid_config) }
    let(:base_url) { valid_config.base_url }
    let(:items_response) do
      {
        "data" => [
          { "id" => "item-1", "datasetId" => "ds-1" },
          { "id" => "item-2", "datasetId" => "ds-1" }
        ],
        "meta" => {}
      }
    end

    before do
      stub_request(:get, "#{base_url}/api/public/dataset-items")
        .with(query: { datasetName: "my-dataset" })
        .to_return(
          status: 200,
          body: items_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns array of DatasetItemClient instances" do
      result = client.list_dataset_items(dataset_name: "my-dataset")
      expect(result).to be_an(Array)
      expect(result).to all(be_a(Langfuse::DatasetItemClient))
    end

    it "returns correct number of items" do
      result = client.list_dataset_items(dataset_name: "my-dataset")
      expect(result.size).to eq(2)
    end

    it "wraps items with correct data" do
      result = client.list_dataset_items(dataset_name: "my-dataset")
      expect(result.first.id).to eq("item-1")
      expect(result.last.id).to eq("item-2")
    end

    context "with source filter parameters" do
      before do
        stub_request(:get, "#{base_url}/api/public/dataset-items")
          .with(query: { datasetName: "my-dataset", sourceTraceId: "trace-abc", sourceObservationId: "obs-xyz" })
          .to_return(
            status: 200,
            body: items_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "passes source_trace_id and source_observation_id to the API" do
        client.list_dataset_items(
          dataset_name: "my-dataset",
          source_trace_id: "trace-abc",
          source_observation_id: "obs-xyz"
        )

        expect(
          a_request(:get, "#{base_url}/api/public/dataset-items")
            .with(query: { datasetName: "my-dataset", sourceTraceId: "trace-abc", sourceObservationId: "obs-xyz" })
        ).to have_been_made.once
      end
    end
  end

  describe "#delete_dataset_item" do
    let(:client) { described_class.new(valid_config) }
    let(:base_url) { valid_config.base_url }

    context "with successful response" do
      before do
        stub_request(:delete, "#{base_url}/api/public/dataset-items/item-123")
          .to_return(
            status: 200,
            body: { "id" => "item-123" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns nil" do
        result = client.delete_dataset_item("item-123")
        expect(result).to be_nil
      end

      it "makes DELETE request" do
        client.delete_dataset_item("item-123")
        expect(
          a_request(:delete, "#{base_url}/api/public/dataset-items/item-123")
        ).to have_been_made.once
      end
    end

    context "when not found" do
      before do
        stub_request(:delete, "#{base_url}/api/public/dataset-items/missing")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "returns nil" do
        result = client.delete_dataset_item("missing")
        expect(result).to be_nil
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:delete, "#{base_url}/api/public/dataset-items/item-123")
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect { client.delete_dataset_item("item-123") }.to raise_error(Langfuse::UnauthorizedError)
      end
    end
  end
end
