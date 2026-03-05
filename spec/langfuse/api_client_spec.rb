# frozen_string_literal: true

RSpec.describe Langfuse::ApiClient do
  let(:public_key) { "pk_test_123" }
  let(:secret_key) { "sk_test_456" }
  let(:base_url) { "https://cloud.langfuse.com" }
  let(:api_client) do
    described_class.new(
      public_key: public_key,
      secret_key: secret_key,
      base_url: base_url,
      timeout: 10
    )
  end

  describe "#initialize" do
    it "sets public_key" do
      expect(api_client.public_key).to eq(public_key)
    end

    it "sets secret_key" do
      expect(api_client.secret_key).to eq(secret_key)
    end

    it "sets base_url" do
      expect(api_client.base_url).to eq(base_url)
    end

    it "sets timeout" do
      expect(api_client.timeout).to eq(10)
    end

    it "creates a default logger when none provided" do
      expect(api_client.logger).to be_a(Logger)
    end

    it "accepts a custom logger" do
      custom_logger = Logger.new($stdout)
      client = described_class.new(
        public_key: public_key,
        secret_key: secret_key,
        base_url: base_url,
        logger: custom_logger
      )
      expect(client.logger).to eq(custom_logger)
    end
  end

  describe "#connection" do
    it "returns a Faraday connection" do
      expect(api_client.connection).to be_a(Faraday::Connection)
    end

    it "memoizes the connection" do
      conn1 = api_client.connection
      conn2 = api_client.connection
      expect(conn1).to eq(conn2)
    end

    it "creates a new connection with custom timeout" do
      default_conn = api_client.connection
      custom_conn = api_client.connection(timeout: 20)

      expect(custom_conn).to be_a(Faraday::Connection)
      expect(custom_conn).not_to eq(default_conn)
    end

    it "configures the connection with correct base URL" do
      conn = api_client.connection
      expect(conn.url_prefix.to_s).to eq("#{base_url}/")
    end

    it "includes Authorization header" do
      conn = api_client.connection
      expect(conn.headers["Authorization"]).to start_with("Basic ")
    end

    it "includes User-Agent header" do
      conn = api_client.connection
      expect(conn.headers["User-Agent"]).to eq("langfuse-rb/#{Langfuse::VERSION}")
    end

    it "includes Content-Type header" do
      conn = api_client.connection
      expect(conn.headers["Content-Type"]).to eq("application/json")
    end
  end

  describe "#authorization_header" do
    it "generates correct Basic Auth header" do
      # Basic Auth format: "Basic " + base64(public_key:secret_key)
      expected_credentials = "#{public_key}:#{secret_key}"
      expected_encoded = Base64.strict_encode64(expected_credentials)
      expected_header = "Basic #{expected_encoded}"

      auth_header = api_client.send(:authorization_header)
      expect(auth_header).to eq(expected_header)
    end

    it "uses strict encoding (no newlines)" do
      auth_header = api_client.send(:authorization_header)
      expect(auth_header).not_to include("\n")
    end

    it "works with special characters in credentials" do
      client = described_class.new(
        public_key: "pk_test!@#$%",
        secret_key: "sk_test^&*()",
        base_url: base_url
      )

      auth_header = client.send(:authorization_header)
      expect(auth_header).to start_with("Basic ")

      # Decode and verify
      encoded = auth_header.sub("Basic ", "")
      decoded = Base64.strict_decode64(encoded)
      expect(decoded).to eq("pk_test!@#$%:sk_test^&*()")
    end
  end

  describe "#user_agent" do
    it "includes gem name and version" do
      user_agent = api_client.send(:user_agent)
      expect(user_agent).to eq("langfuse-rb/#{Langfuse::VERSION}")
    end
  end

  describe "timeout configuration" do
    it "uses default timeout when none specified" do
      client = described_class.new(
        public_key: public_key,
        secret_key: secret_key,
        base_url: base_url
      )
      conn = client.connection
      expect(conn.options.timeout).to eq(5)
    end

    it "uses custom timeout when specified" do
      conn = api_client.connection
      expect(conn.options.timeout).to eq(10)
    end

    it "overrides timeout for specific connection" do
      conn = api_client.connection(timeout: 30)
      expect(conn.options.timeout).to eq(30)
    end
  end

  describe "connection middleware" do
    let(:conn) { api_client.connection }

    it "includes JSON request middleware" do
      handlers = conn.builder.handlers.map(&:name)
      expect(handlers).to include("Faraday::Request::Json")
    end

    it "includes JSON response middleware" do
      handlers = conn.builder.handlers.map(&:name)
      expect(handlers).to include("Faraday::Response::Json")
    end

    it "uses Faraday default adapter" do
      # Adapter is configured but may not show in handlers list in Faraday 2.x
      # We'll verify it works when making actual requests in Phase 1.3
      expect(conn.adapter).to eq(Faraday::Adapter::NetHttp)
    end
  end

  describe "#get_prompt" do
    let(:prompt_name) { "greeting" }
    let(:prompt_response) do
      {
        "id" => "prompt-123",
        "name" => "greeting",
        "version" => 1,
        "prompt" => "Hello {{name}}!",
        "type" => "text",
        "labels" => ["production"]
      }
    end

    context "with successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .to_return(
            status: 200,
            body: prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "fetches a prompt by name" do
        result = api_client.get_prompt(prompt_name)
        expect(result).to eq(prompt_response)
      end

      it "makes a GET request to the correct endpoint" do
        api_client.get_prompt(prompt_name)
        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
        ).to have_been_made.once
      end
    end

    context "with version parameter" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .with(query: { version: "2" })
          .to_return(
            status: 200,
            body: prompt_response.merge("version" => 2).to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "includes version in query parameters" do
        result = api_client.get_prompt(prompt_name, version: 2)
        expect(result["version"]).to eq(2)
      end

      it "makes request with version parameter" do
        api_client.get_prompt(prompt_name, version: 2)
        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
            .with(query: { version: "2" })
        ).to have_been_made.once
      end
    end

    context "with label parameter" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .with(query: { label: "production" })
          .to_return(
            status: 200,
            body: prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "includes label in query parameters" do
        result = api_client.get_prompt(prompt_name, label: "production")
        expect(result["labels"]).to include("production")
      end

      it "makes request with label parameter" do
        api_client.get_prompt(prompt_name, label: "production")
        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
            .with(query: { label: "production" })
        ).to have_been_made.once
      end
    end

    context "with both version and label" do
      it "raises ArgumentError" do
        expect do
          api_client.get_prompt(prompt_name, version: 2, label: "production")
        end.to raise_error(ArgumentError, "Cannot specify both version and label")
      end
    end

    context "when prompt is not found" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "raises NotFoundError" do
        expect do
          api_client.get_prompt(prompt_name)
        end.to raise_error(Langfuse::NotFoundError, "Not found")
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect do
          api_client.get_prompt(prompt_name)
        end.to raise_error(Langfuse::UnauthorizedError, "Authentication failed. Check your API keys.")
      end
    end

    context "when API returns an error" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .to_return(
            status: 500,
            body: { message: "Internal server error" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ApiError with status code and message" do
        expect do
          api_client.get_prompt(prompt_name)
        end.to raise_error(Langfuse::ApiError, /API request failed \(500\): Internal server error/)
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .to_timeout
      end

      it "raises ApiError" do
        expect do
          api_client.get_prompt(prompt_name)
        end.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end

    # rubocop:disable RSpec/MultipleMemoizedHelpers
    context "with caching enabled" do
      let(:cache) { instance_double(Langfuse::PromptCache) }
      let(:cached_client) do
        described_class.new(
          public_key: public_key,
          secret_key: secret_key,
          base_url: base_url,
          cache: cache
        )
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .to_return(
            status: 200,
            body: prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "stores response in cache" do
        cache_key = Langfuse::PromptCache.build_key(prompt_name)

        expect(cache).to receive(:respond_to?).with(:swr_enabled?).and_return(false)
        expect(cache).to receive(:respond_to?).with(:fetch_with_lock).and_return(false)
        expect(cache).to receive(:get).with(cache_key).and_return(nil)
        expect(cache).to receive(:set).with(cache_key, prompt_response)

        cached_client.get_prompt(prompt_name)
      end

      it "returns cached response on second call" do
        cache_key = Langfuse::PromptCache.build_key(prompt_name)

        # First call - cache miss
        expect(cache).to receive(:respond_to?).with(:swr_enabled?).and_return(false)
        expect(cache).to receive(:respond_to?).with(:fetch_with_lock).and_return(false)
        expect(cache).to receive(:get).with(cache_key).and_return(nil)
        expect(cache).to receive(:set).with(cache_key, prompt_response)
        first_result = cached_client.get_prompt(prompt_name)

        # Second call - cache hit
        expect(cache).to receive(:respond_to?).with(:swr_enabled?).and_return(false)
        expect(cache).to receive(:respond_to?).with(:fetch_with_lock).and_return(false)
        expect(cache).to receive(:get).with(cache_key).and_return(prompt_response)
        second_result = cached_client.get_prompt(prompt_name)

        expect(second_result).to eq(first_result)
      end

      it "builds correct cache key with version" do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .with(query: { version: "2" })
          .to_return(
            status: 200,
            body: prompt_response.merge("version" => 2).to_json,
            headers: { "Content-Type" => "application/json" }
          )

        cache_key = Langfuse::PromptCache.build_key(prompt_name, version: 2)
        versioned_response = prompt_response.merge("version" => 2)

        expect(cache).to receive(:respond_to?).with(:swr_enabled?).and_return(false)
        expect(cache).to receive(:respond_to?).with(:fetch_with_lock).and_return(false)
        expect(cache).to receive(:get).with(cache_key).and_return(nil)
        expect(cache).to receive(:set).with(cache_key, versioned_response)

        cached_client.get_prompt(prompt_name, version: 2)
      end

      it "builds correct cache key with label" do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .with(query: { label: "production" })
          .to_return(
            status: 200,
            body: prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        cache_key = Langfuse::PromptCache.build_key(prompt_name, label: "production")

        expect(cache).to receive(:respond_to?).with(:swr_enabled?).and_return(false)
        expect(cache).to receive(:respond_to?).with(:fetch_with_lock).and_return(false)
        expect(cache).to receive(:get).with(cache_key).and_return(nil)
        expect(cache).to receive(:set).with(cache_key, prompt_response)

        cached_client.get_prompt(prompt_name, label: "production")
      end

      it "caches different versions separately" do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .with(query: { version: "1" })
          .to_return(
            status: 200,
            body: prompt_response.merge("version" => 1).to_json,
            headers: { "Content-Type" => "application/json" }
          )

        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .with(query: { version: "2" })
          .to_return(
            status: 200,
            body: prompt_response.merge("version" => 2).to_json,
            headers: { "Content-Type" => "application/json" }
          )

        cache_key_v1 = Langfuse::PromptCache.build_key(prompt_name, version: 1)
        cache_key_v2 = Langfuse::PromptCache.build_key(prompt_name, version: 2)
        v1_response = prompt_response.merge("version" => 1)
        v2_response = prompt_response.merge("version" => 2)

        # First call for version 1
        expect(cache).to receive(:respond_to?).with(:swr_enabled?).and_return(false)
        expect(cache).to receive(:respond_to?).with(:fetch_with_lock).and_return(false)
        expect(cache).to receive(:get).with(cache_key_v1).and_return(nil)
        expect(cache).to receive(:set).with(cache_key_v1, v1_response)

        cached_client.get_prompt(prompt_name, version: 1)

        # First call for version 2
        expect(cache).to receive(:respond_to?).with(:swr_enabled?).and_return(false)
        expect(cache).to receive(:respond_to?).with(:fetch_with_lock).and_return(false)
        expect(cache).to receive(:get).with(cache_key_v2).and_return(nil)
        expect(cache).to receive(:set).with(cache_key_v2, v2_response)

        cached_client.get_prompt(prompt_name, version: 2)
      end
    end

    context "with SWR caching integration" do
      let(:logger) { Logger.new($stdout, level: Logger::WARN) }
      let(:prompt_data) do
        {
          "id" => "prompt123",
          "name" => "greeting",
          "version" => 1,
          "type" => "text",
          "prompt" => "Hello {{name}}!",
          "labels" => ["production"],
          "tags" => ["customer-facing"],
          "config" => {}
        }
      end

      context "with SWR-enabled cache" do
        it "uses SWR fetch method when available" do
          swr_cache = instance_double(Langfuse::RailsCacheAdapter)
          cache_key = "greeting:version:1"

          client = described_class.new(
            public_key: public_key,
            secret_key: secret_key,
            base_url: base_url,
            logger: logger,
            cache: swr_cache
          )

          allow(swr_cache).to receive(:respond_to?)
            .with(:swr_enabled?)
            .and_return(true)
          allow(swr_cache).to receive(:swr_enabled?)
            .and_return(true)

          expect(Langfuse::PromptCache).to receive(:build_key)
            .with("greeting", version: 1, label: nil)
            .and_return(cache_key)

          expect(swr_cache).to receive(:fetch_with_stale_while_revalidate)
            .with(cache_key)
            .and_yield
            .and_return(prompt_data)

          expect(client).to receive(:fetch_prompt_from_api)
            .with("greeting", version: 1, label: nil)
            .and_return(prompt_data)

          result = client.get_prompt("greeting", version: 1)
          expect(result).to eq(prompt_data)
        end

        it "handles cache miss with SWR" do
          swr_cache = instance_double(Langfuse::RailsCacheAdapter)

          client = described_class.new(
            public_key: public_key,
            secret_key: secret_key,
            base_url: base_url,
            logger: logger,
            cache: swr_cache
          )

          allow(swr_cache).to receive(:respond_to?)
            .with(:swr_enabled?)
            .and_return(true)
          allow(swr_cache).to receive(:swr_enabled?)
            .and_return(true)

          expect(Langfuse::PromptCache).to receive(:build_key)
            .with("greeting", version: nil, label: nil)
            .and_return("greeting:latest")

          expect(swr_cache).to receive(:fetch_with_stale_while_revalidate)
            .with("greeting:latest")
            .and_yield
            .and_return(prompt_data)

          stub_request(:get, "#{base_url}/api/public/v2/prompts/greeting")
            .to_return(
              status: 200,
              body: prompt_data.to_json,
              headers: { "Content-Type" => "application/json" }
            )

          result = client.get_prompt("greeting")
          expect(result).to eq(prompt_data)
        end

        it "passes through all prompt parameters to cache key building" do
          swr_cache = instance_double(Langfuse::RailsCacheAdapter)

          client = described_class.new(
            public_key: public_key,
            secret_key: secret_key,
            base_url: base_url,
            logger: logger,
            cache: swr_cache
          )

          allow(swr_cache).to receive(:respond_to?)
            .with(:swr_enabled?)
            .and_return(true)
          allow(swr_cache).to receive(:swr_enabled?)
            .and_return(true)

          expect(Langfuse::PromptCache).to receive(:build_key)
            .with("support-bot", version: nil, label: "staging")
            .and_return("support-bot:label:staging")

          expect(swr_cache).to receive(:fetch_with_stale_while_revalidate)
            .with("support-bot:label:staging")
            .and_return(prompt_data)

          client.get_prompt("support-bot", label: "staging")
        end
      end

      context "with stampede protection cache (no SWR)" do
        it "falls back to stampede protection when SWR not available" do
          stampede_cache = instance_double(Langfuse::RailsCacheAdapter)
          cache_key = "greeting:version:1"

          client = described_class.new(
            public_key: public_key,
            secret_key: secret_key,
            base_url: base_url,
            logger: logger,
            cache: stampede_cache
          )

          allow(stampede_cache).to receive(:respond_to?)
            .with(:swr_enabled?)
            .and_return(false)
          allow(stampede_cache).to receive(:respond_to?)
            .with(:fetch_with_lock)
            .and_return(true)

          expect(Langfuse::PromptCache).to receive(:build_key)
            .with("greeting", version: 1, label: nil)
            .and_return(cache_key)

          expect(stampede_cache).to receive(:fetch_with_lock)
            .with(cache_key)
            .and_yield
            .and_return(prompt_data)

          expect(client).to receive(:fetch_prompt_from_api)
            .with("greeting", version: 1, label: nil)
            .and_return(prompt_data)

          result = client.get_prompt("greeting", version: 1)
          expect(result).to eq(prompt_data)
        end
      end

      context "with simple cache (no SWR, no stampede protection)" do
        it "uses simple get/set pattern when advanced caching not available" do
          simple_cache = instance_double(Langfuse::PromptCache)

          client = described_class.new(
            public_key: public_key,
            secret_key: secret_key,
            base_url: base_url,
            logger: logger,
            cache: simple_cache
          )

          allow(simple_cache).to receive(:respond_to?)
            .with(:swr_enabled?)
            .and_return(false)
          allow(simple_cache).to receive(:respond_to?)
            .with(:fetch_with_lock)
            .and_return(false)

          expect(Langfuse::PromptCache).to receive(:build_key)
            .with("greeting", version: nil, label: nil)
            .and_return("greeting:latest")

          expect(simple_cache).to receive(:get)
            .with("greeting:latest")
            .and_return(nil)

          expect(client).to receive(:fetch_prompt_from_api)
            .with("greeting", version: nil, label: nil)
            .and_return(prompt_data)

          expect(simple_cache).to receive(:set)
            .with("greeting:latest", prompt_data)

          result = client.get_prompt("greeting")
          expect(result).to eq(prompt_data)
        end

        it "returns cached data when available" do
          simple_cache = instance_double(Langfuse::PromptCache)

          client = described_class.new(
            public_key: public_key,
            secret_key: secret_key,
            base_url: base_url,
            logger: logger,
            cache: simple_cache
          )

          allow(simple_cache).to receive(:respond_to?)
            .with(:swr_enabled?)
            .and_return(false)
          allow(simple_cache).to receive(:respond_to?)
            .with(:fetch_with_lock)
            .and_return(false)

          expect(Langfuse::PromptCache).to receive(:build_key)
            .with("greeting", version: nil, label: nil)
            .and_return("greeting:latest")

          expect(simple_cache).to receive(:get)
            .with("greeting:latest")
            .and_return(prompt_data)

          expect(client).not_to receive(:fetch_prompt_from_api)
          expect(simple_cache).not_to receive(:set)

          result = client.get_prompt("greeting")
          expect(result).to eq(prompt_data)
        end
      end

      context "with no cache" do
        it "fetches directly from API without caching" do
          client = described_class.new(
            public_key: public_key,
            secret_key: secret_key,
            base_url: base_url,
            logger: logger,
            cache: nil
          )

          expect(client).to receive(:fetch_prompt_from_api)
            .with("greeting", version: nil, label: nil)
            .and_return(prompt_data)

          result = client.get_prompt("greeting")
          expect(result).to eq(prompt_data)
        end
      end

      context "when detecting cache capabilities" do
        it "correctly detects SWR capability" do
          swr_cache = instance_double(Langfuse::RailsCacheAdapter)

          client = described_class.new(
            public_key: public_key,
            secret_key: secret_key,
            base_url: base_url,
            cache: swr_cache
          )

          allow(swr_cache).to receive(:respond_to?)
            .with(:swr_enabled?)
            .and_return(true)

          expect(swr_cache).to receive(:fetch_with_stale_while_revalidate)
          allow(swr_cache).to receive_messages(swr_enabled?: true, fetch_with_stale_while_revalidate: prompt_data)

          client.get_prompt("test")
        end

        it "falls back when SWR not available but stampede protection is" do
          rails_cache = instance_double(Langfuse::RailsCacheAdapter)

          client = described_class.new(
            public_key: public_key,
            secret_key: secret_key,
            base_url: base_url,
            cache: rails_cache
          )

          allow(rails_cache).to receive(:respond_to?)
            .with(:swr_enabled?)
            .and_return(false)
          allow(rails_cache).to receive(:respond_to?)
            .with(:fetch_with_lock)
            .and_return(true)

          expect(rails_cache).to receive(:fetch_with_lock)
          allow(rails_cache).to receive(:fetch_with_lock)
            .and_return(prompt_data)

          client.get_prompt("test")
        end

        it "handles nil cache gracefully" do
          client = described_class.new(
            public_key: public_key,
            secret_key: secret_key,
            base_url: base_url,
            cache: nil
          )

          expect(client).to receive(:fetch_prompt_from_api)
            .and_return(prompt_data)

          result = client.get_prompt("test")
          expect(result).to eq(prompt_data)
        end
      end

      context "when handling errors with SWR" do
        it "propagates API errors when SWR cache fails" do
          swr_cache = instance_double(Langfuse::RailsCacheAdapter)

          client = described_class.new(
            public_key: public_key,
            secret_key: secret_key,
            base_url: base_url,
            logger: logger,
            cache: swr_cache
          )

          allow(swr_cache).to receive(:respond_to?)
            .with(:swr_enabled?)
            .and_return(true)
          allow(swr_cache).to receive(:swr_enabled?)
            .and_return(true)

          allow(swr_cache).to receive(:fetch_with_stale_while_revalidate)
            .and_yield

          expect(client).to receive(:fetch_prompt_from_api)
            .and_raise(Langfuse::NotFoundError, "Not found")

          expect do
            client.get_prompt("nonexistent")
          end.to raise_error(Langfuse::NotFoundError, "Not found")
        end
      end
    end
    # rubocop:enable RSpec/MultipleMemoizedHelpers

    context "with retry middleware configuration" do
      # NOTE: Direct retry behavior testing is challenging with WebMock due to
      # known incompatibilities. These tests verify the middleware is properly
      # configured. Actual retry behavior is tested in integration tests.

      it "includes retry middleware in connection" do
        conn = api_client.connection
        handlers = conn.builder.handlers.map(&:name)
        expect(handlers).to include("Faraday::Retry::Middleware")
      end

      it "configures retry with correct max attempts" do
        options = api_client.send(:retry_options)
        expect(options[:max]).to eq(2)
      end

      it "configures retry with exponential backoff" do
        options = api_client.send(:retry_options)
        expect(options[:interval]).to eq(0.05)
        expect(options[:backoff_factor]).to eq(2)
      end

      it "configures retry for GET, POST, PATCH, and DELETE requests" do
        options = api_client.send(:retry_options)
        expect(options[:methods]).to contain_exactly(:get, :post, :patch, :delete)
      end

      it "configures retry for transient error status codes" do
        options = api_client.send(:retry_options)
        expect(options[:retry_statuses]).to contain_exactly(429, 503, 504)
      end

      it "configures retry for network errors" do
        options = api_client.send(:retry_options)
        expect(options[:exceptions]).to include(
          Faraday::TimeoutError,
          Faraday::ConnectionFailed
        )
      end

      it "handles retry exhaustion by raising appropriate error" do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .to_return(status: 429)

        expect do
          api_client.get_prompt(prompt_name)
        end.to raise_error(Langfuse::ApiError, /API request failed \(429\)/)
      end

      it "does not retry on non-retriable status codes" do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .to_return(status: 404, body: { message: "Not found" }.to_json)

        expect do
          api_client.get_prompt(prompt_name)
        end.to raise_error(Langfuse::NotFoundError)

        # Verify only 1 attempt
        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
        ).to have_been_made.once
      end
    end

    context "with Faraday error handling" do
      it "handles Faraday::RetriableResponse (retries exhausted)" do
        # Create a mock response with body
        mock_response = instance_double(Faraday::Response, status: 503, body: { "message" => "Service unavailable" })
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)

        # Stub the connection to raise the error
        allow(api_client.connection).to receive(:get).and_raise(retriable_error)

        expect(api_client.logger).to receive(:error).with(/Retries exhausted - 503/)
        expect do
          api_client.get_prompt(prompt_name)
        end.to raise_error(Langfuse::ApiError, /API request failed \(503\): Service unavailable/)
      end

      it "handles generic Faraday::Error" do
        faraday_error = Faraday::Error.new("Connection failed")

        # Stub the connection to raise the error
        allow(api_client.connection).to receive(:get).and_raise(faraday_error)

        expect(api_client.logger).to receive(:error).with(/Faraday error: Connection failed/)
        expect do
          api_client.get_prompt(prompt_name)
        end.to raise_error(Langfuse::ApiError, /HTTP request failed: Connection failed/)
      end
    end

    context "with URL encoding of special characters in prompt names" do
      let(:prompt_response) do
        {
          "id" => "prompt-123",
          "name" => "greeting",
          "version" => 1,
          "prompt" => "Hello {{name}}!",
          "type" => "text",
          "labels" => ["production"]
        }
      end

      it "encodes special characters in prompt names" do
        prompt_name = "my/prompt name?special"
        encoded_name = URI.encode_uri_component(prompt_name)

        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{encoded_name}")
          .to_return(
            status: 200,
            body: prompt_response.merge("name" => prompt_name).to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = api_client.get_prompt(prompt_name)
        expect(result["name"]).to eq(prompt_name)
        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts/#{encoded_name}")
        ).to have_been_made.once
      end
    end

    # rubocop:disable RSpec/MultipleMemoizedHelpers
    context "with Rails cache backend (fetch_with_lock)" do
      let(:rails_cache) do
        # Create a simple object that responds to fetch_with_lock
        Class.new do
          def respond_to?(method, include_private: false)
            method == :fetch_with_lock || super
          end

          def fetch_with_lock(_key)
            result = yield if block_given?
            @cached_value ||= result
            @cached_value || result
          end

          def get(_key)
            @cached_value
          end

          def set(_key, value)
            @cached_value = value
          end
        end.new
      end

      let(:rails_cached_client) do
        described_class.new(
          public_key: public_key,
          secret_key: secret_key,
          base_url: base_url,
          cache: rails_cache
        )
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .to_return(
            status: 200,
            body: prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "uses fetch_with_lock for distributed locking" do
        cache_key = Langfuse::PromptCache.build_key(prompt_name)
        expect(rails_cache).to receive(:fetch_with_lock).with(cache_key).and_call_original

        result = rails_cached_client.get_prompt(prompt_name)
        expect(result).to eq(prompt_response)
      end

      it "calls fetch_prompt_from_api within the lock block" do
        expect(rails_cached_client).to receive(:fetch_prompt_from_api).with(
          prompt_name,
          version: nil,
          label: nil
        ).and_call_original

        rails_cached_client.get_prompt(prompt_name)
      end
    end
    # rubocop:enable RSpec/MultipleMemoizedHelpers
  end

  describe "#create_prompt" do
    let(:prompt_name) { "new-prompt" }
    let(:text_prompt_request) do
      {
        name: prompt_name,
        prompt: "Hello {{name}}!",
        type: "text",
        config: { model: "gpt-4o" },
        labels: ["staging"],
        tags: ["greeting"]
      }
    end
    let(:created_prompt_response) do
      {
        "id" => "prompt-new",
        "name" => prompt_name,
        "version" => 1,
        "type" => "text",
        "prompt" => "Hello {{name}}!",
        "config" => { "model" => "gpt-4o" },
        "labels" => ["staging"],
        "tags" => ["greeting"]
      }
    end

    context "with successful response" do
      before do
        stub_request(:post, "#{base_url}/api/public/v2/prompts")
          .to_return(
            status: 201,
            body: created_prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "creates a prompt and returns data" do
        result = api_client.create_prompt(**text_prompt_request)
        expect(result["name"]).to eq(prompt_name)
        expect(result["version"]).to eq(1)
      end

      it "makes POST request to correct endpoint" do
        api_client.create_prompt(**text_prompt_request)
        expect(
          a_request(:post, "#{base_url}/api/public/v2/prompts")
        ).to have_been_made.once
      end

      it "sends correct payload" do
        api_client.create_prompt(**text_prompt_request)
        expect(
          a_request(:post, "#{base_url}/api/public/v2/prompts")
            .with(body: hash_including(
              "name" => prompt_name,
              "prompt" => "Hello {{name}}!",
              "type" => "text"
            ))
        ).to have_been_made.once
      end
    end

    # rubocop:disable RSpec/MultipleMemoizedHelpers
    context "with chat prompt" do
      let(:chat_prompt_request) do
        {
          name: "chat-prompt",
          prompt: [{ "role" => "system", "content" => "You are helpful" }],
          type: "chat",
          config: {},
          labels: [],
          tags: []
        }
      end
      let(:created_chat_response) do
        {
          "id" => "prompt-chat",
          "name" => "chat-prompt",
          "version" => 1,
          "type" => "chat",
          "prompt" => [{ "role" => "system", "content" => "You are helpful" }],
          "config" => {},
          "labels" => [],
          "tags" => []
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

      it "creates a chat prompt" do
        result = api_client.create_prompt(**chat_prompt_request)
        expect(result["type"]).to eq("chat")
        expect(result["prompt"]).to be_an(Array)
      end
    end
    # rubocop:enable RSpec/MultipleMemoizedHelpers

    context "with commit message" do
      before do
        stub_request(:post, "#{base_url}/api/public/v2/prompts")
          .to_return(
            status: 201,
            body: created_prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "includes commit message in payload" do
        api_client.create_prompt(**text_prompt_request, commit_message: "Initial version")
        expect(
          a_request(:post, "#{base_url}/api/public/v2/prompts")
            .with(body: hash_including("commitMessage" => "Initial version"))
        ).to have_been_made.once
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:post, "#{base_url}/api/public/v2/prompts")
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect do
          api_client.create_prompt(**text_prompt_request)
        end.to raise_error(Langfuse::UnauthorizedError, "Authentication failed. Check your API keys.")
      end
    end

    context "when API returns an error" do
      before do
        stub_request(:post, "#{base_url}/api/public/v2/prompts")
          .to_return(
            status: 400,
            body: { message: "Invalid prompt type" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ApiError with status code and message" do
        expect do
          api_client.create_prompt(**text_prompt_request)
        end.to raise_error(Langfuse::ApiError, /API request failed \(400\): Invalid prompt type/)
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:post, "#{base_url}/api/public/v2/prompts")
          .to_timeout
      end

      it "raises ApiError" do
        expect do
          api_client.create_prompt(**text_prompt_request)
        end.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end
  end

  describe "#update_prompt" do
    let(:prompt_name) { "existing-prompt" }
    let(:version) { 2 }
    let(:updated_prompt_response) do
      {
        "id" => "prompt-123",
        "name" => prompt_name,
        "version" => version,
        "type" => "text",
        "prompt" => "Hello {{name}}!",
        "labels" => ["production"],
        "tags" => []
      }
    end

    context "with successful response" do
      before do
        stub_request(:patch, "#{base_url}/api/public/v2/prompts/#{prompt_name}/versions/#{version}")
          .to_return(
            status: 200,
            body: updated_prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "updates prompt and returns data" do
        result = api_client.update_prompt(
          name: prompt_name,
          version: version,
          labels: ["production"]
        )
        expect(result["labels"]).to include("production")
      end

      it "makes PATCH request to correct endpoint" do
        api_client.update_prompt(name: prompt_name, version: version, labels: ["production"])
        expect(
          a_request(:patch, "#{base_url}/api/public/v2/prompts/#{prompt_name}/versions/#{version}")
        ).to have_been_made.once
      end

      it "sends newLabels in payload" do
        api_client.update_prompt(name: prompt_name, version: version, labels: ["production"])
        expect(
          a_request(:patch, "#{base_url}/api/public/v2/prompts/#{prompt_name}/versions/#{version}")
            .with(body: { "newLabels" => ["production"] })
        ).to have_been_made.once
      end

      it "supports empty labels array" do
        api_client.update_prompt(name: prompt_name, version: version, labels: [])
        expect(
          a_request(:patch, "#{base_url}/api/public/v2/prompts/#{prompt_name}/versions/#{version}")
            .with(body: { "newLabels" => [] })
        ).to have_been_made.once
      end
    end

    context "with invalid labels argument" do
      it "raises ArgumentError when labels is nil" do
        expect do
          api_client.update_prompt(name: prompt_name, version: version, labels: nil)
        end.to raise_error(ArgumentError, "labels must be an array")
      end

      it "raises ArgumentError when labels is a string" do
        expect do
          api_client.update_prompt(name: prompt_name, version: version, labels: "production")
        end.to raise_error(ArgumentError, "labels must be an array")
      end

      it "raises ArgumentError when labels is a hash" do
        expect do
          api_client.update_prompt(name: prompt_name, version: version, labels: { name: "production" })
        end.to raise_error(ArgumentError, "labels must be an array")
      end
    end

    context "when prompt not found" do
      before do
        stub_request(:patch, "#{base_url}/api/public/v2/prompts/#{prompt_name}/versions/#{version}")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "raises NotFoundError" do
        expect do
          api_client.update_prompt(name: prompt_name, version: version, labels: ["production"])
        end.to raise_error(Langfuse::NotFoundError, "Not found")
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:patch, "#{base_url}/api/public/v2/prompts/#{prompt_name}/versions/#{version}")
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect do
          api_client.update_prompt(name: prompt_name, version: version, labels: ["production"])
        end.to raise_error(Langfuse::UnauthorizedError, "Authentication failed. Check your API keys.")
      end
    end

    context "when API returns an error" do
      before do
        stub_request(:patch, "#{base_url}/api/public/v2/prompts/#{prompt_name}/versions/#{version}")
          .to_return(
            status: 500,
            body: { message: "Internal server error" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "raises ApiError with status code and message" do
        expect do
          api_client.update_prompt(name: prompt_name, version: version, labels: ["production"])
        end.to raise_error(Langfuse::ApiError, /API request failed \(500\): Internal server error/)
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:patch, "#{base_url}/api/public/v2/prompts/#{prompt_name}/versions/#{version}")
          .to_timeout
      end

      it "raises ApiError" do
        expect do
          api_client.update_prompt(name: prompt_name, version: version, labels: ["production"])
        end.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end

    context "with URL encoding of special characters in prompt names" do
      it "encodes special characters in prompt names" do
        prompt_name = "my/prompt name?special"
        encoded_name = URI.encode_uri_component(prompt_name)
        version = 2

        stub_request(:patch, "#{base_url}/api/public/v2/prompts/#{encoded_name}/versions/#{version}")
          .to_return(
            status: 200,
            body: { "name" => prompt_name, "version" => version }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = api_client.update_prompt(name: prompt_name, version: version, labels: ["production"])
        expect(result["name"]).to eq(prompt_name)
        expect(
          a_request(:patch, "#{base_url}/api/public/v2/prompts/#{encoded_name}/versions/#{version}")
        ).to have_been_made.once
      end
    end
  end

  describe "#send_batch" do
    let(:events) do
      [
        {
          id: SecureRandom.uuid,
          type: "score-create",
          timestamp: Time.now.utc.iso8601(3),
          body: {
            name: "quality",
            value: 0.85,
            trace_id: "abc123",
            data_type: "NUMERIC"
          }
        },
        {
          id: SecureRandom.uuid,
          type: "score-create",
          timestamp: Time.now.utc.iso8601(3),
          body: {
            name: "accuracy",
            value: 0.92,
            trace_id: "def456",
            data_type: "NUMERIC"
          }
        }
      ]
    end

    context "with valid events" do
      it "sends batch to ingestion endpoint" do
        stub_request(:post, "#{base_url}/api/public/ingestion")
          .with(
            body: { batch: events }.to_json,
            headers: {
              "Authorization" => /^Basic /,
              "Content-Type" => "application/json",
              "User-Agent" => "langfuse-rb/#{Langfuse::VERSION}"
            }
          )
          .to_return(status: 200, body: "", headers: {})

        expect { api_client.send_batch(events) }.not_to raise_error
      end

      it "handles 201 Created response" do
        stub_request(:post, "#{base_url}/api/public/ingestion")
          .to_return(status: 201, body: "", headers: {})

        expect { api_client.send_batch(events) }.not_to raise_error
      end

      it "handles 204 No Content response" do
        stub_request(:post, "#{base_url}/api/public/ingestion")
          .to_return(status: 204, body: "", headers: {})

        expect { api_client.send_batch(events) }.not_to raise_error
      end
    end

    context "with validation errors" do
      it "raises ArgumentError for non-array input" do
        expect do
          api_client.send_batch("not an array")
        end.to raise_error(ArgumentError, "events must be an array")
      end

      it "raises ArgumentError for empty array" do
        expect do
          api_client.send_batch([])
        end.to raise_error(ArgumentError, "events array cannot be empty")
      end
    end

    context "with API errors" do
      it "raises UnauthorizedError for 401" do
        stub_request(:post, "#{base_url}/api/public/ingestion")
          .to_return(
            status: 401,
            body: { error: "Unauthorized" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        expect do
          api_client.send_batch(events)
        end.to raise_error(Langfuse::UnauthorizedError, "Authentication failed. Check your API keys.")
      end

      it "raises ApiError for other error statuses" do
        stub_request(:post, "#{base_url}/api/public/ingestion")
          .to_return(
            status: 500,
            body: { error: "Internal Server Error" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        expect do
          api_client.send_batch(events)
        end.to raise_error(Langfuse::ApiError, /Batch send failed/)
      end

      it "handles network errors" do
        stub_request(:post, "#{base_url}/api/public/ingestion")
          .to_raise(Faraday::ConnectionFailed.new("Connection failed"))

        expect do
          api_client.send_batch(events)
        end.to raise_error(Langfuse::ApiError, /Batch send failed/)
      end
    end

    context "with retry logic for batch operations" do
      # NOTE: Direct retry behavior testing is challenging with WebMock due to
      # known incompatibilities. These tests verify the middleware is properly
      # configured and test retry behavior using mocks. Actual retry behavior
      # for status codes is tested in integration tests.

      it "retries on transient network errors (ConnectionFailed)" do
        # First attempt fails with connection error, second succeeds
        stub_request(:post, "#{base_url}/api/public/ingestion")
          .to_raise(Faraday::ConnectionFailed.new("Connection failed"))
          .then
          .to_return(status: 200, body: "", headers: {})

        expect { api_client.send_batch(events) }.not_to raise_error

        # Verify retry happened (should be 2 requests)
        expect(
          a_request(:post, "#{base_url}/api/public/ingestion")
        ).to have_been_made.times(2)
      end

      it "retries on timeout errors" do
        # First attempt times out, second succeeds
        stub_request(:post, "#{base_url}/api/public/ingestion")
          .to_timeout
          .then
          .to_return(status: 200, body: "", headers: {})

        expect { api_client.send_batch(events) }.not_to raise_error

        # Verify retry happened
        expect(
          a_request(:post, "#{base_url}/api/public/ingestion")
        ).to have_been_made.times(2)
      end

      it "configures retry for POST requests to batch endpoint" do
        options = api_client.send(:retry_options)
        expect(options[:methods]).to include(:post)
      end

      it "configures retry for transient error status codes (429, 503, 504)" do
        options = api_client.send(:retry_options)
        expect(options[:retry_statuses]).to include(429, 503, 504)
      end

      it "handles Faraday::RetriableResponse after retries exhausted for 429" do
        # Simulate retry middleware exhausting retries for 429
        mock_response = instance_double(
          Faraday::Response,
          status: 429,
          body: { "error" => "Rate limit exceeded" }
        )
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)

        allow(api_client.connection).to receive(:post).and_raise(retriable_error)

        expect(api_client.logger).to receive(:error).with(/Retries exhausted - 429/)
        expect do
          api_client.send_batch(events)
        end.to raise_error(Langfuse::ApiError, /Batch send failed \(429\)/)
      end

      it "handles Faraday::RetriableResponse after retries exhausted for 503" do
        # Simulate retry middleware exhausting retries for 503
        mock_response = instance_double(
          Faraday::Response,
          status: 503,
          body: { "error" => "Service unavailable" }
        )
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)

        allow(api_client.connection).to receive(:post).and_raise(retriable_error)

        expect(api_client.logger).to receive(:error).with(/Retries exhausted - 503/)
        expect do
          api_client.send_batch(events)
        end.to raise_error(Langfuse::ApiError, /Batch send failed \(503\)/)
      end

      it "handles Faraday::RetriableResponse after retries exhausted for 504" do
        # Simulate retry middleware exhausting retries for 504
        mock_response = instance_double(
          Faraday::Response,
          status: 504,
          body: { "error" => "Gateway timeout" }
        )
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)

        allow(api_client.connection).to receive(:post).and_raise(retriable_error)

        expect(api_client.logger).to receive(:error).with(/Retries exhausted - 504/)
        expect do
          api_client.send_batch(events)
        end.to raise_error(Langfuse::ApiError, /Batch send failed \(504\)/)
      end

      it "does not retry on non-retriable errors (401)" do
        # 401 should not be retried
        stub_request(:post, "#{base_url}/api/public/ingestion")
          .to_return(
            status: 401,
            body: { error: "Unauthorized" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        expect do
          api_client.send_batch(events)
        end.to raise_error(Langfuse::UnauthorizedError)

        # Should only attempt once
        expect(
          a_request(:post, "#{base_url}/api/public/ingestion")
        ).to have_been_made.once
      end

      it "does not retry on non-retriable errors (400)" do
        # 400 should not be retried
        stub_request(:post, "#{base_url}/api/public/ingestion")
          .to_return(
            status: 400,
            body: { error: "Bad Request" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        expect do
          api_client.send_batch(events)
        end.to raise_error(Langfuse::ApiError, /Batch send failed \(400\)/)

        # Should only attempt once
        expect(
          a_request(:post, "#{base_url}/api/public/ingestion")
        ).to have_been_made.once
      end
    end
  end

  describe "#shutdown" do
    context "when cache supports shutdown" do
      let(:swr_cache) do
        Langfuse::PromptCache.new(
          ttl: 60,
          stale_ttl: 120,
          refresh_threads: 2
        )
      end
      let(:api_client_with_swr) do
        described_class.new(
          public_key: public_key,
          secret_key: secret_key,
          base_url: base_url,
          cache: swr_cache
        )
      end

      it "calls shutdown on the cache" do
        expect(swr_cache).to receive(:shutdown).and_call_original

        api_client_with_swr.shutdown
      end

      it "does not raise an error" do
        expect { api_client_with_swr.shutdown }.not_to raise_error
      end
    end

    context "when cache does not support shutdown" do
      let(:ttl_cache) do
        Langfuse::PromptCache.new(
          ttl: 60,
          stale_ttl: 0
        )
      end
      let(:api_client_with_ttl_only) do
        described_class.new(
          public_key: public_key,
          secret_key: secret_key,
          base_url: base_url,
          cache: ttl_cache
        )
      end

      it "does not raise an error" do
        expect { api_client_with_ttl_only.shutdown }.not_to raise_error
      end

      it "calls shutdown on the cache (which returns early when no thread pool)" do
        # shutdown is safe to call even when stale_ttl is 0 (no thread pool)
        # The method returns early if @thread_pool is nil
        expect(ttl_cache).to receive(:shutdown).and_call_original

        api_client_with_ttl_only.shutdown
      end
    end

    context "when cache is nil" do
      let(:api_client_no_cache) do
        described_class.new(
          public_key: public_key,
          secret_key: secret_key,
          base_url: base_url,
          cache: nil
        )
      end

      it "does not raise an error" do
        expect { api_client_no_cache.shutdown }.not_to raise_error
      end
    end
  end

  describe "#list_datasets" do
    let(:datasets_response) do
      {
        "data" => [
          { "id" => "ds-1", "name" => "dataset-1" },
          { "id" => "ds-2", "name" => "dataset-2" }
        ],
        "meta" => { "totalItems" => 2 }
      }
    end

    context "with successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/datasets")
          .to_return(
            status: 200,
            body: datasets_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns array of datasets" do
        result = api_client.list_datasets
        expect(result).to be_an(Array)
        expect(result.size).to eq(2)
      end

      it "makes GET request to correct endpoint" do
        api_client.list_datasets
        expect(
          a_request(:get, "#{base_url}/api/public/v2/datasets")
        ).to have_been_made.once
      end
    end

    context "with pagination" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/datasets")
          .with(query: { page: "2", limit: "10" })
          .to_return(
            status: 200,
            body: datasets_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "passes pagination parameters" do
        api_client.list_datasets(page: 2, limit: 10)
        expect(
          a_request(:get, "#{base_url}/api/public/v2/datasets")
            .with(query: { page: "2", limit: "10" })
        ).to have_been_made.once
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/datasets")
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect { api_client.list_datasets }.to raise_error(Langfuse::UnauthorizedError)
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/datasets")
          .to_timeout
      end

      it "raises ApiError" do
        expect { api_client.list_datasets }.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end

    context "when retries exhausted" do
      it "handles Faraday::RetriableResponse" do
        mock_response = instance_double(Faraday::Response, status: 503, body: { "message" => "Service unavailable" })
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)
        allow(api_client.connection).to receive(:get).and_raise(retriable_error)

        expect { api_client.list_datasets }.to raise_error(Langfuse::ApiError, /API request failed \(503\)/)
      end
    end
  end

  describe "#get_dataset" do
    let(:dataset_name) { "evaluation-qa" }
    let(:dataset_response) do
      {
        "id" => "ds-123",
        "name" => dataset_name,
        "description" => "QA dataset"
      }
    end

    context "with successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/datasets/#{dataset_name}")
          .to_return(
            status: 200,
            body: dataset_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns dataset data" do
        result = api_client.get_dataset(dataset_name)
        expect(result["id"]).to eq("ds-123")
        expect(result["name"]).to eq(dataset_name)
      end
    end

    context "with folder-style name" do
      it "URL-encodes dataset name" do
        folder_name = "evaluation/qa-dataset"
        encoded_name = "evaluation%2Fqa-dataset"

        stub_request(:get, "#{base_url}/api/public/v2/datasets/#{encoded_name}")
          .to_return(
            status: 200,
            body: { "id" => "ds-1", "name" => folder_name }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = api_client.get_dataset(folder_name)
        expect(result["name"]).to eq(folder_name)
        expect(
          a_request(:get, "#{base_url}/api/public/v2/datasets/#{encoded_name}")
        ).to have_been_made.once
      end
    end

    context "when not found" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/datasets/#{dataset_name}")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { api_client.get_dataset(dataset_name) }.to raise_error(Langfuse::NotFoundError)
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/datasets/#{dataset_name}")
          .to_timeout
      end

      it "raises ApiError" do
        expect { api_client.get_dataset(dataset_name) }.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end

    context "when retries exhausted" do
      it "handles Faraday::RetriableResponse" do
        mock_response = instance_double(Faraday::Response, status: 503, body: { "message" => "Service unavailable" })
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)
        allow(api_client.connection).to receive(:get).and_raise(retriable_error)

        expect { api_client.get_dataset(dataset_name) }.to raise_error(Langfuse::ApiError, /API request failed \(503\)/)
      end
    end
  end

  describe "#create_dataset" do
    let(:created_dataset) do
      {
        "id" => "ds-new",
        "name" => "new-dataset",
        "description" => "A new dataset"
      }
    end

    context "with successful response" do
      before do
        stub_request(:post, "#{base_url}/api/public/v2/datasets")
          .to_return(
            status: 201,
            body: created_dataset.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns created dataset" do
        result = api_client.create_dataset(name: "new-dataset")
        expect(result["id"]).to eq("ds-new")
      end

      it "sends correct payload" do
        api_client.create_dataset(
          name: "new-dataset",
          description: "A new dataset",
          metadata: { "key" => "value" }
        )
        expect(
          a_request(:post, "#{base_url}/api/public/v2/datasets")
            .with(body: hash_including(
              "name" => "new-dataset",
              "description" => "A new dataset",
              "metadata" => { "key" => "value" }
            ))
        ).to have_been_made.once
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:post, "#{base_url}/api/public/v2/datasets")
          .to_timeout
      end

      it "raises ApiError" do
        expect { api_client.create_dataset(name: "test") }.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end

    context "when retries exhausted" do
      it "handles Faraday::RetriableResponse" do
        mock_response = instance_double(Faraday::Response, status: 503, body: { "message" => "Service unavailable" })
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)
        allow(api_client.connection).to receive(:post).and_raise(retriable_error)

        expect do
          api_client.create_dataset(name: "test")
        end.to raise_error(Langfuse::ApiError, /API request failed \(503\)/)
      end
    end
  end

  describe "#create_dataset_item" do
    let(:created_item) do
      {
        "id" => "item-new",
        "datasetId" => "ds-123",
        "input" => { "q" => "test" }
      }
    end

    context "with successful response" do
      before do
        stub_request(:post, "#{base_url}/api/public/dataset-items")
          .to_return(
            status: 201,
            body: created_item.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns created item" do
        result = api_client.create_dataset_item(dataset_name: "my-dataset")
        expect(result["id"]).to eq("item-new")
      end

      it "sends camelCase datasetName" do
        api_client.create_dataset_item(dataset_name: "my-dataset", input: { "q" => "test" })
        expect(
          a_request(:post, "#{base_url}/api/public/dataset-items")
            .with(body: hash_including("datasetName" => "my-dataset"))
        ).to have_been_made.once
      end

      it "converts status symbol to uppercase" do
        api_client.create_dataset_item(dataset_name: "my-dataset", status: :archived)
        expect(
          a_request(:post, "#{base_url}/api/public/dataset-items")
            .with(body: hash_including("status" => "ARCHIVED"))
        ).to have_been_made.once
      end

      it "sends all optional parameters with camelCase keys" do
        api_client.create_dataset_item(
          dataset_name: "my-dataset",
          input: { "q" => "test" },
          expected_output: { "a" => "answer" },
          metadata: { "key" => "value" },
          id: "custom-id",
          source_trace_id: "trace-123",
          source_observation_id: "obs-456",
          status: :active
        )
        expect(
          a_request(:post, "#{base_url}/api/public/dataset-items")
            .with(body: hash_including(
              "datasetName" => "my-dataset",
              "input" => { "q" => "test" },
              "expectedOutput" => { "a" => "answer" },
              "metadata" => { "key" => "value" },
              "id" => "custom-id",
              "sourceTraceId" => "trace-123",
              "sourceObservationId" => "obs-456",
              "status" => "ACTIVE"
            ))
        ).to have_been_made.once
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:post, "#{base_url}/api/public/dataset-items")
          .to_timeout
      end

      it "raises ApiError" do
        expect do
          api_client.create_dataset_item(dataset_name: "test")
        end.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end

    context "when retries exhausted" do
      it "handles Faraday::RetriableResponse" do
        mock_response = instance_double(Faraday::Response, status: 503, body: { "message" => "Service unavailable" })
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)
        allow(api_client.connection).to receive(:post).and_raise(retriable_error)

        expect do
          api_client.create_dataset_item(dataset_name: "test")
        end.to raise_error(Langfuse::ApiError, /API request failed \(503\)/)
      end
    end
  end

  describe "#get_dataset_item" do
    let(:item_id) { "item-123" }
    let(:item_response) do
      {
        "id" => item_id,
        "datasetId" => "ds-456",
        "input" => { "q" => "test" }
      }
    end

    context "with successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/dataset-items/#{item_id}")
          .to_return(
            status: 200,
            body: item_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns item data" do
        result = api_client.get_dataset_item(item_id)
        expect(result["id"]).to eq(item_id)
      end
    end

    context "when not found" do
      before do
        stub_request(:get, "#{base_url}/api/public/dataset-items/#{item_id}")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { api_client.get_dataset_item(item_id) }.to raise_error(Langfuse::NotFoundError)
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:get, "#{base_url}/api/public/dataset-items/#{item_id}")
          .to_timeout
      end

      it "raises ApiError" do
        expect { api_client.get_dataset_item(item_id) }.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end

    context "when retries exhausted" do
      it "handles Faraday::RetriableResponse" do
        mock_response = instance_double(Faraday::Response, status: 503, body: { "message" => "Service unavailable" })
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)
        allow(api_client.connection).to receive(:get).and_raise(retriable_error)

        expect { api_client.get_dataset_item(item_id) }.to raise_error(Langfuse::ApiError, /API request failed \(503\)/)
      end
    end
  end

  describe "#list_dataset_items" do
    let(:dataset_name) { "my-dataset" }
    let(:items_response) do
      {
        "data" => [
          { "id" => "item-1", "datasetId" => "ds-1" },
          { "id" => "item-2", "datasetId" => "ds-1" }
        ],
        "meta" => {}
      }
    end

    context "with successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/dataset-items")
          .with(query: { datasetName: dataset_name })
          .to_return(
            status: 200,
            body: items_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns array of item hashes" do
        result = api_client.list_dataset_items(dataset_name: dataset_name)
        expect(result).to be_an(Array)
        expect(result.size).to eq(2)
        expect(result.first["id"]).to eq("item-1")
      end

      it "sends datasetName query parameter" do
        api_client.list_dataset_items(dataset_name: dataset_name)
        expect(
          a_request(:get, "#{base_url}/api/public/dataset-items")
            .with(query: hash_including("datasetName" => dataset_name))
        ).to have_been_made.once
      end
    end

    context "with all filters" do
      before do
        stub_request(:get, "#{base_url}/api/public/dataset-items")
          .with(query: {
                  datasetName: dataset_name,
                  page: "2",
                  limit: "10",
                  sourceTraceId: "trace-123",
                  sourceObservationId: "obs-456"
                })
          .to_return(
            status: 200,
            body: items_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "passes all filter parameters with camelCase" do
        api_client.list_dataset_items(
          dataset_name: dataset_name,
          page: 2,
          limit: 10,
          source_trace_id: "trace-123",
          source_observation_id: "obs-456"
        )
        expect(
          a_request(:get, "#{base_url}/api/public/dataset-items")
            .with(query: hash_including(
              "datasetName" => dataset_name,
              "page" => "2",
              "limit" => "10",
              "sourceTraceId" => "trace-123",
              "sourceObservationId" => "obs-456"
            ))
        ).to have_been_made.once
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:get, "#{base_url}/api/public/dataset-items")
          .with(query: { datasetName: dataset_name })
          .to_timeout
      end

      it "raises ApiError" do
        expect do
          api_client.list_dataset_items(dataset_name: dataset_name)
        end.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end

    context "when retries exhausted" do
      it "handles Faraday::RetriableResponse" do
        mock_response = instance_double(Faraday::Response, status: 503, body: { "message" => "Service unavailable" })
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)
        allow(api_client.connection).to receive(:get).and_raise(retriable_error)

        expect do
          api_client.list_dataset_items(dataset_name: dataset_name)
        end.to raise_error(Langfuse::ApiError,
                           /API request failed \(503\)/)
      end
    end
  end

  describe "#delete_dataset_item" do
    let(:item_id) { "item-123" }

    context "with successful response" do
      before do
        stub_request(:delete, "#{base_url}/api/public/dataset-items/#{item_id}")
          .to_return(
            status: 200,
            body: { "id" => item_id }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "makes DELETE request to correct endpoint" do
        api_client.delete_dataset_item(item_id)
        expect(
          a_request(:delete, "#{base_url}/api/public/dataset-items/#{item_id}")
        ).to have_been_made.once
      end

      it "returns response body" do
        result = api_client.delete_dataset_item(item_id)
        expect(result["id"]).to eq(item_id)
      end
    end

    context "when not found" do
      before do
        stub_request(:delete, "#{base_url}/api/public/dataset-items/#{item_id}")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "treats 404 as success" do
        result = api_client.delete_dataset_item(item_id)
        expect(result["id"]).to eq(item_id)
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:delete, "#{base_url}/api/public/dataset-items/#{item_id}")
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect { api_client.delete_dataset_item(item_id) }.to raise_error(Langfuse::UnauthorizedError)
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:delete, "#{base_url}/api/public/dataset-items/#{item_id}")
          .to_timeout
      end

      it "raises ApiError" do
        expect { api_client.delete_dataset_item(item_id) }.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end

    context "when retries exhausted" do
      it "handles Faraday::RetriableResponse" do
        mock_response = instance_double(Faraday::Response, status: 503, body: { "message" => "Service unavailable" })
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)
        allow(api_client.connection).to receive(:delete).and_raise(retriable_error)

        expect do
          api_client.delete_dataset_item(item_id)
        end.to raise_error(Langfuse::ApiError, /API request failed \(503\)/)
      end
    end
  end

  describe "#get_projects" do
    let(:projects_response) do
      {
        "data" => [
          { "id" => "proj-abc-123", "name" => "my-project" }
        ]
      }
    end

    context "with successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/projects")
          .to_return(
            status: 200,
            body: projects_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns parsed response body" do
        result = api_client.get_projects
        expect(result["data"].first["id"]).to eq("proj-abc-123")
      end

      it "makes GET request to correct endpoint" do
        api_client.get_projects
        expect(
          a_request(:get, "#{base_url}/api/public/projects")
        ).to have_been_made.once
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:get, "#{base_url}/api/public/projects")
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect { api_client.get_projects }.to raise_error(Langfuse::UnauthorizedError)
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:get, "#{base_url}/api/public/projects")
          .to_timeout
      end

      it "raises ApiError" do
        expect { api_client.get_projects }.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end

    context "when retries exhausted" do
      it "handles Faraday::RetriableResponse" do
        mock_response = instance_double(Faraday::Response, status: 503, body: { "message" => "Service unavailable" })
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)
        allow(api_client.connection).to receive(:get).and_raise(retriable_error)

        expect { api_client.get_projects }.to raise_error(Langfuse::ApiError, /API request failed \(503\)/)
      end
    end
  end

  describe "#create_dataset_run_item" do
    let(:run_item_response) do
      {
        "id" => "run-item-1",
        "datasetItemId" => "item-123",
        "runName" => "experiment-1"
      }
    end

    context "with successful response" do
      before do
        stub_request(:post, "#{base_url}/api/public/dataset-run-items")
          .to_return(
            status: 200,
            body: run_item_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns created run item" do
        result = api_client.create_dataset_run_item(
          dataset_item_id: "item-123", run_name: "experiment-1"
        )
        expect(result["id"]).to eq("run-item-1")
      end

      it "sends required camelCase fields" do
        api_client.create_dataset_run_item(
          dataset_item_id: "item-123", run_name: "experiment-1"
        )
        expect(
          a_request(:post, "#{base_url}/api/public/dataset-run-items")
            .with(body: hash_including(
              "datasetItemId" => "item-123",
              "runName" => "experiment-1"
            ))
        ).to have_been_made.once
      end

      it "sends all optional parameters" do
        api_client.create_dataset_run_item(
          dataset_item_id: "item-123",
          run_name: "experiment-1",
          trace_id: "trace-abc",
          observation_id: "obs-def",
          metadata: { "key" => "value" },
          run_description: "test run"
        )
        expect(
          a_request(:post, "#{base_url}/api/public/dataset-run-items")
            .with(body: hash_including(
              "datasetItemId" => "item-123",
              "runName" => "experiment-1",
              "traceId" => "trace-abc",
              "observationId" => "obs-def",
              "metadata" => { "key" => "value" },
              "runDescription" => "test run"
            ))
        ).to have_been_made.once
      end

      it "omits nil optional parameters" do
        api_client.create_dataset_run_item(
          dataset_item_id: "item-123", run_name: "experiment-1"
        )
        expect(
          a_request(:post, "#{base_url}/api/public/dataset-run-items")
            .with do |req|
              body = JSON.parse(req.body)
              !body.key?("traceId") && !body.key?("metadata")
            end
        ).to have_been_made.once
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:post, "#{base_url}/api/public/dataset-run-items")
          .to_timeout
      end

      it "raises ApiError" do
        expect do
          api_client.create_dataset_run_item(
            dataset_item_id: "item-123", run_name: "experiment-1"
          )
        end.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end
  end

  describe "#get_dataset_run" do
    let(:dataset_name) { "evaluation suite/qa" }
    let(:run_name) { "baseline v1/run-a" }

    context "with successful response" do
      before do
        encoded_dataset_name = URI.encode_uri_component(dataset_name)
        encoded_run_name = URI.encode_uri_component(run_name)
        stub_request(:get, "#{base_url}/api/public/datasets/#{encoded_dataset_name}/runs/#{encoded_run_name}")
          .to_return(
            status: 200,
            body: {
              "id" => "run-123",
              "name" => run_name,
              "datasetName" => dataset_name,
              "datasetRunItems" => [{ "id" => "run-item-1" }]
            }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns dataset run data" do
        result = api_client.get_dataset_run(dataset_name: dataset_name, run_name: run_name)
        expect(result["id"]).to eq("run-123")
        expect(result["datasetRunItems"].size).to eq(1)
      end
    end

    context "when not found" do
      before do
        encoded_dataset_name = URI.encode_uri_component(dataset_name)
        encoded_run_name = URI.encode_uri_component(run_name)
        stub_request(:get, "#{base_url}/api/public/datasets/#{encoded_dataset_name}/runs/#{encoded_run_name}")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "raises NotFoundError" do
        expect do
          api_client.get_dataset_run(dataset_name: dataset_name, run_name: run_name)
        end.to raise_error(Langfuse::NotFoundError)
      end
    end

    context "when network error occurs" do
      before do
        encoded_dataset_name = URI.encode_uri_component(dataset_name)
        encoded_run_name = URI.encode_uri_component(run_name)
        stub_request(:get, "#{base_url}/api/public/datasets/#{encoded_dataset_name}/runs/#{encoded_run_name}")
          .to_timeout
      end

      it "raises ApiError" do
        expect do
          api_client.get_dataset_run(dataset_name: dataset_name, run_name: run_name)
        end.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end
  end

  describe "#list_dataset_runs" do
    let(:dataset_name) { "my-dataset" }
    let(:runs_response) do
      {
        "data" => [
          { "id" => "run-1", "name" => "baseline-a" },
          { "id" => "run-2", "name" => "baseline-b" }
        ],
        "meta" => {}
      }
    end

    context "with successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/datasets/my-dataset/runs")
          .to_return(
            status: 200,
            body: runs_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns array of run hashes" do
        result = api_client.list_dataset_runs(dataset_name: dataset_name)
        expect(result).to be_an(Array)
        expect(result.size).to eq(2)
        expect(result.first["id"]).to eq("run-1")
      end
    end

    context "with pagination" do
      before do
        stub_request(:get, "#{base_url}/api/public/datasets/my-dataset/runs")
          .with(query: { page: "2", limit: "10" })
          .to_return(
            status: 200,
            body: runs_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "passes page and limit query parameters" do
        api_client.list_dataset_runs(dataset_name: dataset_name, page: 2, limit: 10)
        expect(
          a_request(:get, "#{base_url}/api/public/datasets/my-dataset/runs")
            .with(query: { "page" => "2", "limit" => "10" })
        ).to have_been_made.once
      end
    end

    context "with dataset names requiring encoding" do
      let(:dataset_name) { "folder name/with spaces" }

      before do
        stub_request(:get, "#{base_url}/api/public/datasets/folder%20name%2Fwith%20spaces/runs")
          .to_return(
            status: 200,
            body: runs_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "encodes dataset name in request path" do
        api_client.list_dataset_runs(dataset_name: dataset_name)

        expect(
          a_request(:get, "#{base_url}/api/public/datasets/folder%20name%2Fwith%20spaces/runs")
        ).to have_been_made.once
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:get, "#{base_url}/api/public/datasets/my-dataset/runs")
          .to_timeout
      end

      it "raises ApiError" do
        expect do
          api_client.list_dataset_runs(dataset_name: dataset_name)
        end.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end
  end

  describe "#delete_dataset_run" do
    let(:dataset_name) { "evaluation suite/qa" }
    let(:run_name) { "baseline v1/run-a" }

    context "with successful response" do
      before do
        encoded_dataset_name = URI.encode_uri_component(dataset_name)
        encoded_run_name = URI.encode_uri_component(run_name)
        stub_request(:delete, "#{base_url}/api/public/datasets/#{encoded_dataset_name}/runs/#{encoded_run_name}")
          .to_return(
            status: 200,
            body: { "deleted" => true }.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns response body" do
        result = api_client.delete_dataset_run(dataset_name: dataset_name, run_name: run_name)
        expect(result["deleted"]).to be(true)
      end
    end

    context "when API returns 204" do
      before do
        encoded_dataset_name = URI.encode_uri_component(dataset_name)
        encoded_run_name = URI.encode_uri_component(run_name)
        stub_request(:delete, "#{base_url}/api/public/datasets/#{encoded_dataset_name}/runs/#{encoded_run_name}")
          .to_return(status: 204, body: "", headers: {})
      end

      it "returns nil" do
        result = api_client.delete_dataset_run(dataset_name: dataset_name, run_name: run_name)
        expect(result).to be_nil
      end
    end

    context "when not found" do
      before do
        encoded_dataset_name = URI.encode_uri_component(dataset_name)
        encoded_run_name = URI.encode_uri_component(run_name)
        stub_request(:delete, "#{base_url}/api/public/datasets/#{encoded_dataset_name}/runs/#{encoded_run_name}")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "raises NotFoundError" do
        expect do
          api_client.delete_dataset_run(dataset_name: dataset_name, run_name: run_name)
        end.to raise_error(Langfuse::NotFoundError)
      end
    end
  end

  describe "#list_traces" do
    let(:traces_response) do
      {
        "data" => [
          { "id" => "trace-1", "name" => "trace-one" },
          { "id" => "trace-2", "name" => "trace-two" }
        ],
        "meta" => { "totalItems" => 2 }
      }
    end

    context "with successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/traces")
          .to_return(
            status: 200,
            body: traces_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns array of traces" do
        result = api_client.list_traces
        expect(result).to be_an(Array)
        expect(result.size).to eq(2)
      end

      it "makes GET request to correct endpoint" do
        api_client.list_traces
        expect(
          a_request(:get, "#{base_url}/api/public/traces")
        ).to have_been_made.once
      end
    end

    context "with pagination" do
      before do
        stub_request(:get, "#{base_url}/api/public/traces")
          .with(query: { page: "2", limit: "10" })
          .to_return(
            status: 200,
            body: traces_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "passes pagination parameters" do
        api_client.list_traces(page: 2, limit: 10)
        expect(
          a_request(:get, "#{base_url}/api/public/traces")
            .with(query: { page: "2", limit: "10" })
        ).to have_been_made.once
      end
    end

    context "with filter parameters" do
      before do
        stub_request(:get, "#{base_url}/api/public/traces")
          .with(query: { userId: "user-1", name: "my-trace", sessionId: "sess-1",
                         tags: %w[tag1 tag2], version: "1.0", release: "prod",
                         environment: "production" })
          .to_return(
            status: 200,
            body: traces_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "maps snake_case params to camelCase query params" do
        api_client.list_traces(
          user_id: "user-1", name: "my-trace", session_id: "sess-1",
          tags: %w[tag1 tag2], version: "1.0", release: "prod",
          environment: "production"
        )
        expect(
          a_request(:get, "#{base_url}/api/public/traces")
            .with(query: { userId: "user-1", name: "my-trace", sessionId: "sess-1",
                           tags: %w[tag1 tag2], version: "1.0", release: "prod",
                           environment: "production" })
        ).to have_been_made.once
      end
    end

    context "with timestamp parameters" do
      let(:from_time) { Time.utc(2025, 1, 1, 12, 0, 0) }
      let(:to_time) { Time.utc(2025, 1, 2, 12, 0, 0) }

      before do
        stub_request(:get, "#{base_url}/api/public/traces")
          .with(query: { fromTimestamp: from_time.iso8601, toTimestamp: to_time.iso8601 })
          .to_return(
            status: 200,
            body: traces_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "serializes timestamps to ISO 8601" do
        api_client.list_traces(from_timestamp: from_time, to_timestamp: to_time)
        expect(
          a_request(:get, "#{base_url}/api/public/traces")
            .with(query: { fromTimestamp: from_time.iso8601, toTimestamp: to_time.iso8601 })
        ).to have_been_made.once
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:get, "#{base_url}/api/public/traces")
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect { api_client.list_traces }.to raise_error(Langfuse::UnauthorizedError)
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:get, "#{base_url}/api/public/traces")
          .to_timeout
      end

      it "raises ApiError" do
        expect { api_client.list_traces }.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end

    context "with filter parameter" do
      before do
        stub_request(:get, "#{base_url}/api/public/traces")
          .with(query: { filter: '[{"type":"string","key":"name","operator":"=","value":"test"}]' })
          .to_return(
            status: 200,
            body: traces_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "passes filter param to query string" do
        filter_json = '[{"type":"string","key":"name","operator":"=","value":"test"}]'
        api_client.list_traces(filter: filter_json)
        expect(
          a_request(:get, "#{base_url}/api/public/traces")
            .with(query: { filter: filter_json })
        ).to have_been_made.once
      end
    end

    context "when retries exhausted" do
      it "handles Faraday::RetriableResponse" do
        mock_response = instance_double(Faraday::Response, status: 503, body: { "message" => "Service unavailable" })
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)
        allow(api_client.connection).to receive(:get).and_raise(retriable_error)

        expect { api_client.list_traces }.to raise_error(Langfuse::ApiError, /API request failed \(503\)/)
      end
    end
  end

  describe "#list_traces_paginated" do
    let(:traces_response) do
      {
        "data" => [
          { "id" => "trace-1", "name" => "trace-one" },
          { "id" => "trace-2", "name" => "trace-two" }
        ],
        "meta" => { "totalItems" => 2, "page" => 1, "limit" => 50, "totalPages" => 1 }
      }
    end

    context "with successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/traces")
          .to_return(
            status: 200,
            body: traces_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns full hash with data and meta keys" do
        result = api_client.list_traces_paginated
        expect(result).to be_a(Hash)
        expect(result).to have_key("data")
        expect(result).to have_key("meta")
      end

      it "includes data array" do
        result = api_client.list_traces_paginated
        expect(result["data"]).to be_an(Array)
        expect(result["data"].size).to eq(2)
      end

      it "includes meta pagination info" do
        result = api_client.list_traces_paginated
        expect(result["meta"]["totalItems"]).to eq(2)
        expect(result["meta"]["totalPages"]).to eq(1)
      end
    end

    context "with filter parameter" do
      before do
        stub_request(:get, "#{base_url}/api/public/traces")
          .with(query: { filter: '[{"type":"string","key":"name","operator":"=","value":"test"}]' })
          .to_return(
            status: 200,
            body: traces_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "passes filter param to query string" do
        filter_json = '[{"type":"string","key":"name","operator":"=","value":"test"}]'
        api_client.list_traces_paginated(filter: filter_json)
        expect(
          a_request(:get, "#{base_url}/api/public/traces")
            .with(query: { filter: filter_json })
        ).to have_been_made.once
      end
    end
  end

  describe "#get_trace" do
    let(:trace_id) { "trace-abc-123" }
    let(:trace_response) do
      {
        "id" => trace_id,
        "name" => "my-trace",
        "userId" => "user-1"
      }
    end

    context "with successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/traces/#{trace_id}")
          .to_return(
            status: 200,
            body: trace_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "returns trace data" do
        result = api_client.get_trace(trace_id)
        expect(result["id"]).to eq(trace_id)
        expect(result["name"]).to eq("my-trace")
      end

      it "makes GET request to correct endpoint" do
        api_client.get_trace(trace_id)
        expect(
          a_request(:get, "#{base_url}/api/public/traces/#{trace_id}")
        ).to have_been_made.once
      end
    end

    context "when not found" do
      before do
        stub_request(:get, "#{base_url}/api/public/traces/#{trace_id}")
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "raises NotFoundError" do
        expect { api_client.get_trace(trace_id) }.to raise_error(Langfuse::NotFoundError)
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:get, "#{base_url}/api/public/traces/#{trace_id}")
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect { api_client.get_trace(trace_id) }.to raise_error(Langfuse::UnauthorizedError)
      end
    end

    context "when network error occurs" do
      before do
        stub_request(:get, "#{base_url}/api/public/traces/#{trace_id}")
          .to_timeout
      end

      it "raises ApiError" do
        expect { api_client.get_trace(trace_id) }.to raise_error(Langfuse::ApiError, /HTTP request failed/)
      end
    end

    context "when retries exhausted" do
      it "handles Faraday::RetriableResponse" do
        mock_response = instance_double(Faraday::Response, status: 503, body: { "message" => "Service unavailable" })
        retriable_error = Faraday::RetriableResponse.new("Retries exhausted", mock_response)
        allow(api_client.connection).to receive(:get).and_raise(retriable_error)

        expect { api_client.get_trace(trace_id) }.to raise_error(Langfuse::ApiError, /API request failed \(503\)/)
      end
    end
  end
end
