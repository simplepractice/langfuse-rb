# frozen_string_literal: true

require "logger"

module Langfuse
  # Configuration object for Langfuse client
  #
  # @example Global configuration
  #   Langfuse.configure do |config|
  #     config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  #     config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  #     config.cache_ttl = 120
  #   end
  #
  # @example Per-client configuration
  #   config = Langfuse::Config.new do |c|
  #     c.public_key = "pk_..."
  #     c.secret_key = "sk_..."
  #   end
  #
  class Config
    # @return [String, nil] Langfuse public API key
    attr_accessor :public_key

    # @return [String, nil] Langfuse secret API key
    attr_accessor :secret_key

    # @return [String] Base URL for Langfuse API
    attr_accessor :base_url

    # @return [Integer] HTTP request timeout in seconds
    attr_accessor :timeout

    # @return [Logger] Logger instance for debugging
    attr_accessor :logger

    # @return [Integer] Cache TTL in seconds
    attr_accessor :cache_ttl

    # @return [Integer] Maximum number of cached items
    attr_accessor :cache_max_size

    # @return [Symbol] Cache backend (:memory or :rails)
    attr_accessor :cache_backend

    # @return [Integer] Lock timeout in seconds for distributed cache stampede protection
    attr_accessor :cache_lock_timeout

    # @return [Boolean] Enable stale-while-revalidate caching
    attr_accessor :cache_stale_while_revalidate

    # @return [Integer] Stale TTL in seconds (grace period for serving stale data)
    attr_accessor :cache_stale_ttl

    # @return [Integer] Number of background threads for cache refresh
    attr_accessor :cache_refresh_threads

    # @return [Boolean] Use async processing for traces (requires ActiveJob)
    attr_accessor :tracing_async

    # @return [Integer] Number of events to batch before sending
    attr_accessor :batch_size

    # @return [Integer] Interval in seconds to flush buffered events
    attr_accessor :flush_interval

    # @return [Symbol] ActiveJob queue name for async processing
    attr_accessor :job_queue

    # Default values
    DEFAULT_BASE_URL = "https://cloud.langfuse.com"
    DEFAULT_TIMEOUT = 5
    DEFAULT_CACHE_TTL = 60
    DEFAULT_CACHE_MAX_SIZE = 1000
    DEFAULT_CACHE_BACKEND = :memory
    DEFAULT_CACHE_LOCK_TIMEOUT = 10
    DEFAULT_CACHE_STALE_WHILE_REVALIDATE = false
    DEFAULT_CACHE_STALE_TTL = 300
    DEFAULT_CACHE_REFRESH_THREADS = 5
    DEFAULT_TRACING_ASYNC = true
    DEFAULT_BATCH_SIZE = 50
    DEFAULT_FLUSH_INTERVAL = 10
    DEFAULT_JOB_QUEUE = :default

    # Initialize a new Config object
    #
    # @yield [config] Optional block for configuration
    # @yieldparam config [Config] The config instance
    def initialize
      @public_key = ENV.fetch("LANGFUSE_PUBLIC_KEY", nil)
      @secret_key = ENV.fetch("LANGFUSE_SECRET_KEY", nil)
      @base_url = ENV.fetch("LANGFUSE_BASE_URL", DEFAULT_BASE_URL)
      @timeout = DEFAULT_TIMEOUT
      @cache_ttl = DEFAULT_CACHE_TTL
      @cache_max_size = DEFAULT_CACHE_MAX_SIZE
      @cache_backend = DEFAULT_CACHE_BACKEND
      @cache_lock_timeout = DEFAULT_CACHE_LOCK_TIMEOUT
      @cache_stale_while_revalidate = DEFAULT_CACHE_STALE_WHILE_REVALIDATE
      @cache_stale_ttl = DEFAULT_CACHE_STALE_TTL
      @cache_refresh_threads = DEFAULT_CACHE_REFRESH_THREADS
      @tracing_async = DEFAULT_TRACING_ASYNC
      @batch_size = DEFAULT_BATCH_SIZE
      @flush_interval = DEFAULT_FLUSH_INTERVAL
      @job_queue = DEFAULT_JOB_QUEUE
      @logger = default_logger

      yield(self) if block_given?
    end

    # Validate the configuration
    #
    # @raise [ConfigurationError] if configuration is invalid
    # @return [void]
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def validate!
      raise ConfigurationError, "public_key is required" if public_key.nil? || public_key.empty?
      raise ConfigurationError, "secret_key is required" if secret_key.nil? || secret_key.empty?
      raise ConfigurationError, "base_url cannot be empty" if base_url.nil? || base_url.empty?
      raise ConfigurationError, "timeout must be positive" if timeout.nil? || timeout <= 0
      raise ConfigurationError, "cache_ttl must be non-negative" if cache_ttl.nil? || cache_ttl.negative?
      raise ConfigurationError, "cache_max_size must be positive" if cache_max_size.nil? || cache_max_size <= 0

      if cache_lock_timeout.nil? || cache_lock_timeout <= 0
        raise ConfigurationError,
              "cache_lock_timeout must be positive"
      end

      validate_swr_config!

      validate_cache_backend!
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    private

    def default_logger
      if defined?(Rails) && Rails.respond_to?(:logger)
        Rails.logger
      else
        Logger.new($stdout, level: Logger::WARN)
      end
    end

    def validate_cache_backend!
      valid_backends = %i[memory rails]
      return if valid_backends.include?(cache_backend)

      raise ConfigurationError,
            "cache_backend must be one of #{valid_backends.inspect}, got #{cache_backend.inspect}"
    end

    def validate_swr_config!
      if cache_stale_ttl.nil? || cache_stale_ttl.negative?
        raise ConfigurationError, "cache_stale_ttl must be non-negative"
      end

      if cache_refresh_threads.nil? || cache_refresh_threads <= 0
        raise ConfigurationError, "cache_refresh_threads must be positive"
      end

      return unless cache_stale_while_revalidate && cache_backend != :rails

      raise ConfigurationError,
            "cache_stale_while_revalidate requires cache_backend to be :rails"
    end
  end
end
