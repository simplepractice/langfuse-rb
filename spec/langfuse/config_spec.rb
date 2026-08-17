# frozen_string_literal: true

RSpec.describe Langfuse::Config do
  describe "#initialize" do
    it "sets default values" do
      config = described_class.new

      expect(config.base_url).to eq("https://cloud.langfuse.com")
      expect(config.timeout).to eq(5)
      expect(config.cache_ttl).to eq(60)
      expect(config.cache_max_size).to eq(1000)
      expect(config.cache_backend).to eq(:memory)
      expect(config.cache_stale_while_revalidate).to be false
      expect(config.cache_stale_ttl).to eq(0) # Defaults to 0 (SWR disabled)
      expect(config.cache_refresh_threads).to eq(5)
      expect(config.should_export_span).to be_nil
      expect(config.sample_rate).to eq(1.0)
    end

    it "reads from environment variables" do
      ENV["LANGFUSE_PUBLIC_KEY"] = "test_public"
      ENV["LANGFUSE_SECRET_KEY"] = "test_secret"
      ENV["LANGFUSE_BASE_URL"] = "https://custom.langfuse.com"
      ENV["LANGFUSE_TRACING_ENVIRONMENT"] = "staging"
      ENV["LANGFUSE_RELEASE"] = "release-123"
      ENV["LANGFUSE_SAMPLE_RATE"] = "0.25"
      ENV["LANGFUSE_TIMEOUT"] = "9"
      ENV["LANGFUSE_FLUSH_AT"] = "25"
      ENV["LANGFUSE_FLUSH_INTERVAL"] = "1.5"
      ENV["LANGFUSE_DEBUG"] = "true"

      config = described_class.new

      expect(config.public_key).to eq("test_public")
      expect(config.secret_key).to eq("test_secret")
      expect(config.base_url).to eq("https://custom.langfuse.com")
      expect(config.environment).to eq("staging")
      expect(config.release).to eq("release-123")
      expect(config.sample_rate).to eq(0.25)
      expect(config.timeout).to eq(9)
      expect(config.batch_size).to eq(25)
      expect(config.flush_interval).to eq(1.5)
      expect(config.logger.level).to eq(Logger::DEBUG)
    ensure
      ENV.delete("LANGFUSE_PUBLIC_KEY")
      ENV.delete("LANGFUSE_SECRET_KEY")
      ENV.delete("LANGFUSE_BASE_URL")
      ENV.delete("LANGFUSE_TRACING_ENVIRONMENT")
      ENV.delete("LANGFUSE_RELEASE")
      ENV.delete("LANGFUSE_SAMPLE_RATE")
      ENV.delete("LANGFUSE_TIMEOUT")
      ENV.delete("LANGFUSE_FLUSH_AT")
      ENV.delete("LANGFUSE_FLUSH_INTERVAL")
      ENV.delete("LANGFUSE_DEBUG")
    end

    it "prefers explicit batching, timeout, and logger settings over environment variables" do
      ENV["LANGFUSE_TIMEOUT"] = "9"
      ENV["LANGFUSE_FLUSH_AT"] = "25"
      ENV["LANGFUSE_FLUSH_INTERVAL"] = "1.5"
      ENV["LANGFUSE_DEBUG"] = "true"

      config = described_class.new do |candidate|
        candidate.timeout = 12
        candidate.batch_size = 30
        candidate.flush_interval = 2
        candidate.logger.level = Logger::ERROR
      end

      expect(config.timeout).to eq(12)
      expect(config.batch_size).to eq(30)
      expect(config.flush_interval).to eq(2)
      expect(config.logger.level).to eq(Logger::ERROR)
    ensure
      ENV.delete("LANGFUSE_TIMEOUT")
      ENV.delete("LANGFUSE_FLUSH_AT")
      ENV.delete("LANGFUSE_FLUSH_INTERVAL")
      ENV.delete("LANGFUSE_DEBUG")
    end

    it "raises ConfigurationError for non-numeric batching and timeout environment values" do
      invalid_values = {
        "LANGFUSE_TIMEOUT" => "slow",
        "LANGFUSE_FLUSH_AT" => "many",
        "LANGFUSE_FLUSH_INTERVAL" => "often"
      }

      invalid_values.each do |key, value|
        ENV[key] = value

        expect { described_class.new }.to raise_error(Langfuse::ConfigurationError, /#{key}/)

        ENV.delete(key)
      end
    ensure
      invalid_values&.each_key { |key| ENV.delete(key) }
    end

    it "raises ConfigurationError for invalid LANGFUSE_SAMPLE_RATE" do
      ENV["LANGFUSE_SAMPLE_RATE"] = "invalid"

      expect { described_class.new }.to raise_error(
        Langfuse::ConfigurationError,
        "sample_rate must be numeric"
      )
    ensure
      ENV.delete("LANGFUSE_SAMPLE_RATE")
    end

    it "does not fallback from explicit 0.0 to LANGFUSE_SAMPLE_RATE" do
      ENV["LANGFUSE_SAMPLE_RATE"] = "0.5"

      config = described_class.new do |c|
        c.sample_rate = 0.0
      end

      expect(config.sample_rate).to eq(0.0)
    ensure
      ENV.delete("LANGFUSE_SAMPLE_RATE")
    end

    it "falls back to CI release environment variables when LANGFUSE_RELEASE is not set" do
      release_envs = Langfuse::Config::COMMON_RELEASE_ENV_KEYS.to_h { |key| [key, ENV.fetch(key, nil)] }
      langfuse_release = ENV.fetch("LANGFUSE_RELEASE", nil)
      ENV.delete("LANGFUSE_RELEASE")
      Langfuse::Config::COMMON_RELEASE_ENV_KEYS.each { |key| ENV.delete(key) }
      ENV["GITHUB_SHA"] = "ci-sha-123"

      config = described_class.new

      expect(config.release).to eq("ci-sha-123")
    ensure
      ENV.delete("GITHUB_SHA")
      langfuse_release.nil? ? ENV.delete("LANGFUSE_RELEASE") : ENV["LANGFUSE_RELEASE"] = langfuse_release
      release_envs.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end

    it "prefers LANGFUSE_RELEASE over CI release environment variables" do
      release_envs = Langfuse::Config::COMMON_RELEASE_ENV_KEYS.to_h { |key| [key, ENV.fetch(key, nil)] }
      langfuse_release = ENV.fetch("LANGFUSE_RELEASE", nil)
      ENV["LANGFUSE_RELEASE"] = "explicit-release"
      Langfuse::Config::COMMON_RELEASE_ENV_KEYS.each { |key| ENV.delete(key) }
      ENV["GITHUB_SHA"] = "ci-sha-123"

      config = described_class.new

      expect(config.release).to eq("explicit-release")
    ensure
      ENV.delete("GITHUB_SHA")
      langfuse_release.nil? ? ENV.delete("LANGFUSE_RELEASE") : ENV["LANGFUSE_RELEASE"] = langfuse_release
      release_envs.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end

    it "accepts block for configuration" do
      config = described_class.new do |c|
        c.public_key = "block_public"
        c.secret_key = "block_secret"
        c.cache_ttl = 120
      end

      expect(config.public_key).to eq("block_public")
      expect(config.secret_key).to eq("block_secret")
      expect(config.cache_ttl).to eq(120)
    end

    it "creates a default logger" do
      config = described_class.new
      expect(config.logger).to be_a(Logger)
    end

    it "uses a null logger when the configured logger is nil" do
      config = described_class.new { |c| c.logger = nil }

      expect(config.logger).to be_a(Logger)
      expect { config.logger.warn("not emitted") }.not_to raise_error
    end

    it "gives each config its own null logger so mutations stay local" do
      config = described_class.new { |c| c.logger = nil }
      other = described_class.new { |c| c.logger = nil }
      original_level = other.logger.level

      config.logger.level = original_level + 1

      expect(other.logger).not_to equal(config.logger)
      expect(other.logger.level).to eq(original_level)
    end

    it "uses the default logger when Rails.logger is nil" do
      rails_class = Class.new do
        def self.logger = nil
      end
      stub_const("Rails", rails_class)

      expect(described_class.new.logger).to be_a(Logger)
    end
  end

  describe "#valid?" do
    let(:config) do
      described_class.new do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
      end
    end

    it "returns true for configuration that can construct a client" do
      expect(config.valid?).to be true
    end

    it "returns false instead of raising for invalid configuration" do
      config.batch_size = "invalid"

      expect(config.valid?).to be false
    end

    it "returns false when a custom logger does not satisfy the logger contract" do
      config.logger = Object.new

      expect(config.valid?).to be false
    end

    it "returns false instead of raising for non-finite or unordered numeric settings" do
      invalid_values = [Complex(1, 1), Float::NAN, Float::INFINITY]
      numeric_settings = %i[
        timeout
        cache_ttl
        cache_max_size
        cache_lock_timeout
        cache_stale_ttl
        cache_refresh_threads
        flush_interval
      ]

      numeric_settings.product(invalid_values).each do |setting, value|
        candidate = config.dup
        candidate.public_send("#{setting}=", value)

        expect(candidate.valid?).to be(false), "expected #{setting}=#{value.inspect} to be invalid"
      end
    end

    it "does not include tracing-only callbacks in client readiness" do
      config.should_export_span = "not callable"
      config.mask = "not callable"
      config.mask_otel_spans = "not callable"

      expect(config.valid?).to be true
      expect { Langfuse::Client.new(config) }.not_to raise_error
    end
  end

  describe "#validate!" do
    let(:config) do
      described_class.new do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
      end
    end

    it "passes validation with valid configuration" do
      expect { config.validate! }.not_to raise_error
    end

    context "when public_key is missing" do
      it "raises ConfigurationError" do
        config.public_key = nil
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "public_key is required"
        )
      end

      it "raises ConfigurationError when empty" do
        config.public_key = ""
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "public_key is required"
        )
      end
    end

    context "when secret_key is missing" do
      it "raises ConfigurationError" do
        config.secret_key = nil
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "secret_key is required"
        )
      end

      it "raises ConfigurationError when empty" do
        config.secret_key = ""
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "secret_key is required"
        )
      end
    end

    context "when base_url is invalid" do
      it "raises ConfigurationError when nil" do
        config.base_url = nil
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "base_url cannot be empty"
        )
      end

      it "raises ConfigurationError when empty" do
        config.base_url = ""
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "base_url cannot be empty"
        )
      end
    end

    context "when timeout is invalid" do
      it "raises ConfigurationError when nil" do
        config.timeout = nil
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "timeout must be positive"
        )
      end

      it "raises ConfigurationError when zero" do
        config.timeout = 0
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "timeout must be positive"
        )
      end

      it "raises ConfigurationError when negative" do
        config.timeout = -1
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "timeout must be positive"
        )
      end

      it "raises ConfigurationError when the value is a String" do
        config.timeout = "5"

        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "timeout must be positive"
        )
      end
    end

    context "when connection settings have invalid types" do
      it "reports a present non-string public key as a type error" do
        config.public_key = 123

        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "public_key must be a String"
        )
      end

      # Credentials are interpolated into the Basic Auth header, so a #to_str-only
      # value would authenticate with its #to_s output rather than the key.
      it "rejects a public key that only responds to #to_str" do
        string_like_key = Object.new
        def string_like_key.to_str = "pk_test"

        config.public_key = string_like_key

        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "public_key must be a String"
        )
      end
    end

    context "when base_url is malformed" do
      ["not-a-url", "://bad", "ftp://langfuse.example.com", "https://"].each do |base_url|
        it "rejects #{base_url.inspect}" do
          config.base_url = base_url

          expect { config.validate! }.to raise_error(
            Langfuse::ConfigurationError,
            "base_url must be an absolute HTTP or HTTPS URL"
          )
        end
      end
    end

    context "when batching settings are invalid" do
      it "raises ConfigurationError when batch_size is a String" do
        config.batch_size = "50"

        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "batch_size must be a positive Integer"
        )
      end

      it "raises ConfigurationError when flush_interval is nil" do
        config.flush_interval = nil

        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "flush_interval must be positive"
        )
      end
    end

    context "when cache_ttl is invalid" do
      it "raises ConfigurationError when nil" do
        config.cache_ttl = nil
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_ttl must be non-negative"
        )
      end

      it "raises ConfigurationError when negative" do
        config.cache_ttl = -1
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_ttl must be non-negative"
        )
      end

      it "allows zero (disabled cache)" do
        config.cache_ttl = 0
        expect { config.validate! }.not_to raise_error
      end

      it "allows positive values" do
        config.cache_ttl = 300
        expect { config.validate! }.not_to raise_error
      end

      it "raises ConfigurationError when the value is a Symbol" do
        config.cache_ttl = :sixty

        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_ttl must be non-negative"
        )
      end
    end

    context "when cache_max_size is invalid" do
      it "raises ConfigurationError when nil" do
        config.cache_max_size = nil
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_max_size must be positive"
        )
      end

      it "raises ConfigurationError when zero" do
        config.cache_max_size = 0
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_max_size must be positive"
        )
      end

      it "raises ConfigurationError when negative" do
        config.cache_max_size = -1
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_max_size must be positive"
        )
      end
    end

    context "when cache_backend is invalid" do
      it "raises ConfigurationError for unknown backend" do
        config.cache_backend = :redis
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          /cache_backend must be one of/
        )
      end

      it "allows :memory backend" do
        config.cache_backend = :memory
        expect { config.validate! }.not_to raise_error
      end

      it "allows :rails backend when Rails.cache is available" do
        rails_class = Class.new do
          def self.cache = Object.new
        end
        stub_const("Rails", rails_class)
        config.cache_backend = :rails

        expect { config.validate! }.not_to raise_error
      end

      it "rejects :rails backend when Rails.cache is unavailable" do
        config.cache_backend = :rails

        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          /Rails\.cache is not available/
        )
      end

      it "allows :auto backend" do
        config.cache_backend = :auto
        expect { config.validate! }.not_to raise_error
      end
    end

    context "when prompt_cache_observer is invalid" do
      it "raises ConfigurationError when observer is not callable" do
        config.prompt_cache_observer = Object.new
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "prompt_cache_observer must respond to #call"
        )
      end

      it "allows callable observers" do
        config.prompt_cache_observer = ->(_event, _payload) {}
        expect { config.validate! }.not_to raise_error
      end
    end

    context "when sample_rate is invalid" do
      it "raises ConfigurationError when below 0.0" do
        expect { config.sample_rate = -0.1 }.to raise_error(
          Langfuse::ConfigurationError,
          "sample_rate must be between 0.0 and 1.0"
        )
      end

      it "raises ConfigurationError when above 1.0" do
        expect { config.sample_rate = 1.1 }.to raise_error(
          Langfuse::ConfigurationError,
          "sample_rate must be between 0.0 and 1.0"
        )
      end

      it "raises ConfigurationError when non-numeric" do
        expect { config.sample_rate = "abc" }.to raise_error(
          Langfuse::ConfigurationError,
          "sample_rate must be numeric"
        )
      end

      it "raises ConfigurationError when the value is a complex number" do
        expect { config.sample_rate = Complex(1, 1) }.to raise_error(
          Langfuse::ConfigurationError,
          "sample_rate must be numeric"
        )
      end

      it "allows 0.0" do
        config.sample_rate = 0.0
        expect { config.validate! }.not_to raise_error
      end

      it "allows 1.0" do
        config.sample_rate = 1.0
        expect { config.validate! }.not_to raise_error
      end
    end

    context "when cache_stale_ttl is invalid" do
      it "raises ConfigurationError when negative" do
        config.cache_stale_ttl = -1
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_stale_ttl must be non-negative or :indefinite"
        )
      end

      it "raises ConfigurationError when nil" do
        config.cache_stale_ttl = nil
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_stale_ttl must be non-negative or :indefinite"
        )
      end

      it "allows zero" do
        config.cache_stale_ttl = 0
        expect { config.validate! }.not_to raise_error
      end

      it "allows positive values" do
        config.cache_stale_ttl = 300
        expect { config.validate! }.not_to raise_error
      end

      it "allows :indefinite symbol" do
        config.cache_stale_ttl = :indefinite
        expect { config.validate! }.not_to raise_error
      end

      it "raises ConfigurationError when the value is a String" do
        config.cache_stale_ttl = "300"

        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_stale_ttl must be non-negative or :indefinite"
        )
      end
    end

    context "when cache_refresh_threads is invalid" do
      it "raises ConfigurationError when nil" do
        config.cache_refresh_threads = nil
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_refresh_threads must be positive"
        )
      end

      it "raises ConfigurationError when zero" do
        config.cache_refresh_threads = 0
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_refresh_threads must be positive"
        )
      end

      it "raises ConfigurationError when negative" do
        config.cache_refresh_threads = -1
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_refresh_threads must be positive"
        )
      end

      it "allows positive values" do
        config.cache_refresh_threads = 5
        expect { config.validate! }.not_to raise_error
      end

      it "raises ConfigurationError when the value is a Symbol" do
        config.cache_refresh_threads = :many

        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          "cache_refresh_threads must be positive"
        )
      end
    end

    context "when validating stale-while-revalidate with cache backend" do
      it "raises ConfigurationError when SWR is enabled but cache_stale_ttl is nil" do
        config.cache_stale_while_revalidate = true
        config.cache_stale_ttl = nil
        expect { config.validate! }.to raise_error(
          Langfuse::ConfigurationError,
          /cache_stale_ttl cannot be nil when cache_stale_while_revalidate is enabled/
        )
      end

      it "allows SWR with auto cache backend" do
        config.cache_backend = :auto
        config.cache_stale_while_revalidate = true
        expect { config.validate! }.not_to raise_error
      end

      it "allows SWR with memory cache backend" do
        config.cache_backend = :memory
        config.cache_stale_while_revalidate = true
        expect { config.validate! }.not_to raise_error
      end

      it "allows SWR disabled with auto cache backend" do
        config.cache_backend = :auto
        config.cache_stale_while_revalidate = false
        expect { config.validate! }.not_to raise_error
      end

      it "allows SWR disabled with memory cache backend" do
        config.cache_backend = :memory
        config.cache_stale_while_revalidate = false
        expect { config.validate! }.not_to raise_error
      end
    end
  end

  describe "#validate_tracing!" do
    let(:config) do
      described_class.new do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
      end
    end

    it "does not validate client-only cache settings" do
      config.cache_backend = :unknown

      expect { config.validate_tracing! }.not_to raise_error
    end

    it "validates shared batching settings" do
      config.batch_size = nil

      expect { config.validate_tracing! }.to raise_error(
        Langfuse::ConfigurationError,
        "batch_size must be a positive Integer"
      )
    end

    it "validates export-stage masking" do
      config.mask_otel_spans = "not callable"

      expect { config.validate_tracing! }.to raise_error(
        Langfuse::ConfigurationError,
        "mask_otel_spans must respond to #call"
      )
    end

    it "validates creation-time masking" do
      config.mask = "not callable"

      expect { config.validate_tracing! }.to raise_error(
        Langfuse::ConfigurationError,
        "mask must respond to #call"
      )
    end

    it "validates the export filter" do
      config.should_export_span = "not callable"

      expect { config.validate_tracing! }.to raise_error(
        Langfuse::ConfigurationError,
        "should_export_span must respond to #call"
      )
    end

    it "validates the logger contract" do
      config.logger = Object.new

      expect { config.validate_tracing! }.to raise_error(
        Langfuse::ConfigurationError,
        "logger must respond to #debug, #info, #warn, #error"
      )
    end
  end

  describe "attribute setters" do
    let(:config) { described_class.new }

    it "allows setting public_key" do
      config.public_key = "new_key"
      expect(config.public_key).to eq("new_key")
    end

    it "allows setting secret_key" do
      config.secret_key = "new_secret"
      expect(config.secret_key).to eq("new_secret")
    end

    it "allows setting base_url" do
      config.base_url = "https://custom.com"
      expect(config.base_url).to eq("https://custom.com")
    end

    it "allows setting timeout" do
      config.timeout = 10
      expect(config.timeout).to eq(10)
    end

    it "allows setting cache_ttl" do
      config.cache_ttl = 300
      expect(config.cache_ttl).to eq(300)
    end

    it "allows setting cache_max_size" do
      config.cache_max_size = 5000
      expect(config.cache_max_size).to eq(5000)
    end

    it "allows setting cache_backend" do
      config.cache_backend = :rails
      expect(config.cache_backend).to eq(:rails)
    end

    it "allows setting logger" do
      custom_logger = Logger.new($stdout)
      config.logger = custom_logger
      expect(config.logger).to eq(custom_logger)
    end

    it "allows setting cache_stale_while_revalidate" do
      config.cache_stale_while_revalidate = true
      expect(config.cache_stale_while_revalidate).to be true
    end

    it "allows setting cache_stale_ttl" do
      config.cache_stale_ttl = 600
      expect(config.cache_stale_ttl).to eq(600)
    end

    it "allows setting cache_stale_ttl to :indefinite" do
      config.cache_stale_ttl = :indefinite
      expect(config.cache_stale_ttl).to eq(:indefinite)
    end

    it "allows setting cache_refresh_threads" do
      config.cache_refresh_threads = 10
      expect(config.cache_refresh_threads).to eq(10)
    end

    it "allows setting environment" do
      config.environment = "production"
      expect(config.environment).to eq("production")
    end

    it "allows setting release" do
      config.release = "release-abc"
      expect(config.release).to eq("release-abc")
    end

    it "allows setting mask to a callable" do
      mask = ->(data:) { data }
      config.mask = mask
      expect(config.mask).to eq(mask)
    end

    it "allows setting mask to nil" do
      config.mask = nil
      expect(config.mask).to be_nil
    end

    it "allows setting sample_rate" do
      config.sample_rate = 0.2
      expect(config.sample_rate).to eq(0.2)
    end
  end

  describe "mask validation" do
    let(:config) do
      described_class.new do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
      end
    end

    it "defaults mask to nil" do
      expect(config.mask).to be_nil
    end

    it "passes validation when mask is nil" do
      config.mask = nil
      expect { config.validate_tracing! }.not_to raise_error
    end

    it "passes validation when mask responds to #call" do
      config.mask = ->(data:) { data }
      expect { config.validate_tracing! }.not_to raise_error
    end

    it "passes validation with a method object" do
      obj = Object.new
      def obj.call(data:) = data
      config.mask = obj
      expect { config.validate_tracing! }.not_to raise_error
    end

    it "fails validation when mask does not respond to #call" do
      config.mask = "not_callable"
      expect { config.validate_tracing! }.to raise_error(
        Langfuse::ConfigurationError,
        "mask must respond to #call"
      )
    end

    it "fails validation when mask is a non-callable object" do
      config.mask = 42
      expect { config.validate_tracing! }.to raise_error(
        Langfuse::ConfigurationError,
        "mask must respond to #call"
      )
    end
  end

  describe "mask_otel_spans validation" do
    let(:config) do
      described_class.new do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
      end
    end

    it "defaults mask_otel_spans to nil" do
      expect(config.mask_otel_spans).to be_nil
    end

    it "passes validation when mask_otel_spans is nil" do
      config.mask_otel_spans = nil
      expect { config.validate_tracing! }.not_to raise_error
    end

    it "passes validation when mask_otel_spans responds to #call" do
      config.mask_otel_spans = ->(params:) { params and nil }
      expect { config.validate_tracing! }.not_to raise_error
    end

    it "fails validation when mask_otel_spans does not respond to #call" do
      config.mask_otel_spans = "not_callable"
      expect { config.validate_tracing! }.to raise_error(
        Langfuse::ConfigurationError,
        "mask_otel_spans must respond to #call"
      )
    end
  end

  describe "stale-while-revalidate integration" do
    before do
      rails_class = Class.new do
        def self.cache = Object.new
      end
      stub_const("Rails", rails_class)
    end

    it "works with all configuration options together" do
      config = described_class.new do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
        c.base_url = "https://test.langfuse.com"
        c.timeout = 10
        c.cache_ttl = 120
        c.cache_backend = :rails
        c.cache_stale_while_revalidate = true
        c.cache_stale_ttl = 240
        c.cache_refresh_threads = 8
      end

      expect { config.validate! }.not_to raise_error

      expect(config.cache_ttl).to eq(120)
      expect(config.cache_stale_while_revalidate).to be true
      expect(config.cache_stale_ttl).to eq(240)
      expect(config.cache_refresh_threads).to eq(8)
    end

    it "maintains backward compatibility when SWR is disabled" do
      config = described_class.new do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
        c.cache_ttl = 60
        c.cache_backend = :rails
      end

      expect { config.validate! }.not_to raise_error

      expect(config.cache_stale_while_revalidate).to be false
      expect(config.cache_stale_ttl).to eq(0) # Defaults to 0 (SWR disabled)
      expect(config.cache_refresh_threads).to eq(5) # Default
    end

    it "allows customizing stale_ttl when SWR is enabled" do
      config = described_class.new do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
        c.cache_ttl = 60
        c.cache_stale_while_revalidate = true
        c.cache_stale_ttl = 180 # Custom value
      end

      expect { config.validate! }.not_to raise_error

      expect(config.cache_stale_while_revalidate).to be true
      expect(config.cache_stale_ttl).to eq(180) # Respects custom value
    end
  end

  describe "constants" do
    it "defines correct SWR default values" do
      expect(Langfuse::Config::DEFAULT_CACHE_STALE_WHILE_REVALIDATE).to be false
      expect(Langfuse::Config::DEFAULT_CACHE_REFRESH_THREADS).to eq(5)
    end
  end

  describe "#normalized_stale_ttl" do
    let(:config) do
      described_class.new do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
      end
    end

    it "returns the numeric value unchanged for regular TTL" do
      config.cache_stale_ttl = 300
      expect(config.normalized_stale_ttl).to eq(300)
    end

    it "returns 0 for zero TTL" do
      config.cache_stale_ttl = 0
      expect(config.normalized_stale_ttl).to eq(0)
    end

    it "returns INDEFINITE_SECONDS when cache_stale_ttl is :indefinite" do
      config.cache_stale_ttl = :indefinite
      expect(config.normalized_stale_ttl).to eq(Langfuse::Config::INDEFINITE_SECONDS)
    end

    it "does not mutate the original cache_stale_ttl value" do
      config.cache_stale_ttl = :indefinite
      config.normalized_stale_ttl # Call normalization
      expect(config.cache_stale_ttl).to eq(:indefinite) # Original value preserved
    end

    it "works with SWR auto-configuration" do
      config_swr = described_class.new do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
        c.cache_ttl = 120
        c.cache_stale_while_revalidate = true
        c.cache_stale_ttl = :indefinite
      end

      expect(config_swr.cache_stale_ttl).to eq(:indefinite)
      expect(config_swr.normalized_stale_ttl).to eq(Langfuse::Config::INDEFINITE_SECONDS)
    end
  end
end
