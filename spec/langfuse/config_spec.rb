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
    end

    it "reads from environment variables" do
      ENV["LANGFUSE_PUBLIC_KEY"] = "test_public"
      ENV["LANGFUSE_SECRET_KEY"] = "test_secret"
      ENV["LANGFUSE_BASE_URL"] = "https://custom.langfuse.com"

      config = described_class.new

      expect(config.public_key).to eq("test_public")
      expect(config.secret_key).to eq("test_secret")
      expect(config.base_url).to eq("https://custom.langfuse.com")
    ensure
      ENV.delete("LANGFUSE_PUBLIC_KEY")
      ENV.delete("LANGFUSE_SECRET_KEY")
      ENV.delete("LANGFUSE_BASE_URL")
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

      it "allows :rails backend" do
        config.cache_backend = :rails
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

      it "allows SWR with Rails cache backend" do
        config.cache_backend = :rails
        config.cache_stale_while_revalidate = true
        expect { config.validate! }.not_to raise_error
      end

      it "allows SWR with memory cache backend" do
        config.cache_backend = :memory
        config.cache_stale_while_revalidate = true
        expect { config.validate! }.not_to raise_error
      end

      it "allows SWR disabled with Rails cache backend" do
        config.cache_backend = :rails
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
  end

  describe "stale-while-revalidate integration" do
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
