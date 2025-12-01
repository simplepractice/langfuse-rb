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
        end.to raise_error(Langfuse::NotFoundError, "Prompt not found")
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
      let(:cache) { Langfuse::PromptCache.new(ttl: 60) }
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
        cached_client.get_prompt(prompt_name)
        cache_key = Langfuse::PromptCache.build_key(prompt_name)
        expect(cache.get(cache_key)).to eq(prompt_response)
      end

      it "returns cached response on second call" do
        # First call - hits API
        first_result = cached_client.get_prompt(prompt_name)

        # Second call - should use cache
        second_result = cached_client.get_prompt(prompt_name)

        expect(second_result).to eq(first_result)
        # Verify API was only called once
        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
        ).to have_been_made.once
      end

      it "builds correct cache key with version" do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .with(query: { version: "2" })
          .to_return(
            status: 200,
            body: prompt_response.merge("version" => 2).to_json,
            headers: { "Content-Type" => "application/json" }
          )

        cached_client.get_prompt(prompt_name, version: 2)
        cache_key = Langfuse::PromptCache.build_key(prompt_name, version: 2)
        expect(cache.get(cache_key)).not_to be_nil
      end

      it "builds correct cache key with label" do
        stub_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
          .with(query: { label: "production" })
          .to_return(
            status: 200,
            body: prompt_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        cached_client.get_prompt(prompt_name, label: "production")
        cache_key = Langfuse::PromptCache.build_key(prompt_name, label: "production")
        expect(cache.get(cache_key)).not_to be_nil
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

        cached_client.get_prompt(prompt_name, version: 1)
        cached_client.get_prompt(prompt_name, version: 2)

        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
            .with(query: { version: "1" })
        ).to have_been_made.once

        expect(
          a_request(:get, "#{base_url}/api/public/v2/prompts/#{prompt_name}")
            .with(query: { version: "2" })
        ).to have_been_made.once
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

      it "configures retry for GET and POST requests" do
        options = api_client.send(:retry_options)
        expect(options[:methods]).to contain_exactly(:get, :post)
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
end
