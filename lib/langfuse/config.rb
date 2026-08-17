# frozen_string_literal: true

require "logger"
require "uri"

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
  # rubocop:disable Metrics/ClassLength
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
    attr_reader :logger

    # @return [Integer] Cache TTL in seconds
    attr_accessor :cache_ttl

    # @return [Integer] Maximum number of cached items
    attr_accessor :cache_max_size

    # @return [Symbol] Cache backend (:memory, :rails, or :auto)
    attr_accessor :cache_backend

    # @return [Integer] Lock timeout in seconds for distributed cache stampede protection
    attr_accessor :cache_lock_timeout

    # @return [Boolean] Enable stale-while-revalidate caching (requires cache_stale_ttl > 0 to activate)
    attr_accessor :cache_stale_while_revalidate

    # @return [Integer, Symbol] Stale TTL in seconds (grace period for serving stale data, default: 0)
    #   Accepts :indefinite which is automatically normalized to 1000 years (31,536,000,000 seconds) for practical "never expire" behavior.
    attr_accessor :cache_stale_ttl

    # @return [Integer] Number of background threads for cache refresh
    attr_accessor :cache_refresh_threads

    # @return [#call, nil] Observer called for prompt cache events
    attr_accessor :prompt_cache_observer

    # @return [Boolean] Use OpenTelemetry batch scheduling for trace export
    attr_accessor :tracing_async

    # @return [Boolean] Enable Langfuse tracing and scoring
    attr_accessor :tracing_enabled

    # @return [Integer] Number of events to batch before sending
    attr_accessor :batch_size

    # @return [Integer] Interval in seconds to flush buffered events
    attr_accessor :flush_interval

    # @return [Integer] Maximum number of asynchronous scores held in memory
    attr_accessor :score_queue_capacity

    # @return [Symbol] Reserved no-op queue name for future async job integration
    attr_accessor :job_queue

    # @return [String, nil] Default tracing environment applied to new traces/observations
    attr_accessor :environment

    # @return [String, nil] Default release identifier applied to new traces/observations
    attr_accessor :release

    # @return [Float] Trace sampling rate from 0.0 to 1.0
    attr_reader :sample_rate

    # @return [#call, nil] Callback that decides whether a span should export to Langfuse.
    #   The span processor calls it once after each span finishes.
    attr_accessor :should_export_span

    # @return [#call, nil] Mask callable applied to input, output, and metadata before serialization.
    #   Receives `data:` keyword argument. nil disables masking.
    #   This is a creation-time hook for Langfuse-owned attributes; it never sees
    #   raw third-party span attributes. See {#mask_otel_spans} for those.
    attr_accessor :mask

    # @return [#call, nil] Export-stage masking hook for spans exported to Langfuse.
    #   Receives a +params:+ keyword argument containing {MaskOtelSpansParams}.
    #   Its frozen +spans+ Hash maps {OtelSpanIdentifier} keys to {OtelSpanData}
    #   snapshots for one export batch, including third-party spans. Returns nil
    #   to export the batch unchanged or {MaskOtelSpansResult} with sparse
    #   {OtelSpanPatch} values. Deletes run before sets.
    #   Only the copy exported to Langfuse is transformed — any other
    #   OpenTelemetry exporter receives the original, unmasked spans, so
    #   Langfuse masking does not protect other telemetry backends.
    #   The hook is synchronous and must not rely on request context, the
    #   current span, async work, or network calls. Exceptions and invalid
    #   results fail closed by dropping the Langfuse export batch.
    attr_accessor :mask_otel_spans

    # @return [#add_to_counter, #record_value, #observe_value, nil] Reporter for
    #   OpenTelemetry batch span processor metrics. The reporter must be fast,
    #   thread-safe, and nonblocking. The application owns its lifecycle.
    attr_accessor :metrics_reporter

    # @return [#export, #force_flush, #shutdown, nil] Span exporter used by
    #   Langfuse's internal tracer provider. The provider owns the exporter
    #   lifecycle after tracing starts. nil selects the default OTLP exporter.
    attr_accessor :span_exporter

    # @return [String] Default Langfuse API base URL
    DEFAULT_BASE_URL = "https://cloud.langfuse.com"

    # @return [Integer] Default HTTP request timeout in seconds
    DEFAULT_TIMEOUT = 5

    # @return [Integer] Default cache TTL in seconds
    DEFAULT_CACHE_TTL = 60

    # @return [Integer] Default maximum number of cached items
    DEFAULT_CACHE_MAX_SIZE = 1000

    # @return [Symbol] Default cache backend
    DEFAULT_CACHE_BACKEND = :memory

    # @return [Integer] Default lock timeout in seconds for cache stampede protection
    DEFAULT_CACHE_LOCK_TIMEOUT = 10

    # @return [Boolean] Default stale-while-revalidate setting
    DEFAULT_CACHE_STALE_WHILE_REVALIDATE = false

    # @return [Integer] Default number of background threads for cache refresh
    DEFAULT_CACHE_REFRESH_THREADS = 5

    # @return [Boolean] Default async processing setting
    DEFAULT_TRACING_ASYNC = true

    # @return [Boolean] Default telemetry setting
    DEFAULT_TRACING_ENABLED = true

    # @return [Integer] Default number of events to batch before sending
    DEFAULT_BATCH_SIZE = 50

    # @return [Integer] Default flush interval in seconds
    DEFAULT_FLUSH_INTERVAL = 10

    # @return [Integer] Default maximum number of queued asynchronous scores
    DEFAULT_SCORE_QUEUE_CAPACITY = 100_000

    # @return [Symbol] Default ActiveJob queue name
    DEFAULT_JOB_QUEUE = :default

    # @return [Float] Default trace sampling rate (sample all traces)
    DEFAULT_SAMPLE_RATE = 1.0

    # @return [Array<Symbol>] Methods required from a custom logger
    LOGGER_METHODS = %i[debug info warn error].freeze

    # Methods defined by OpenTelemetry's metrics reporter contract.
    METRICS_REPORTER_METHODS = %i[add_to_counter record_value observe_value].freeze
    private_constant :METRICS_REPORTER_METHODS

    # Methods required by OpenTelemetry's span exporter contract.
    SPAN_EXPORTER_METHODS = %i[export force_flush shutdown].freeze
    private_constant :SPAN_EXPORTER_METHODS

    # @return [Integer] Number of seconds representing indefinite cache duration (~1000 years)
    INDEFINITE_SECONDS = 1000 * 365 * 24 * 60 * 60

    # @return [Array<String>] Common CI environment variables that contain a release SHA
    COMMON_RELEASE_ENV_KEYS = %w[
      RENDER_GIT_COMMIT
      CI_COMMIT_SHA
      CIRCLE_SHA1
      SOURCE_VERSION
      TRAVIS_COMMIT
      GIT_COMMIT
      GITHUB_SHA
      BITBUCKET_COMMIT
      BUILD_SOURCEVERSION
      DRONE_COMMIT_SHA
    ].freeze

    # Initialize a new Config object
    #
    # @yield [config] Optional block for configuration
    # @yieldparam config [Config] The config instance
    # @return [Config] a new Config instance
    def initialize
      @public_key = ENV.fetch("LANGFUSE_PUBLIC_KEY", nil)
      @secret_key = ENV.fetch("LANGFUSE_SECRET_KEY", nil)
      @base_url = ENV.fetch("LANGFUSE_BASE_URL", DEFAULT_BASE_URL)
      initialize_client_defaults
      initialize_tracing_defaults
      initialize_logger

      yield(self) if block_given?
    end

    # Set the logger. A nil value disables output while preserving the logger contract.
    #
    # @param value [Logger, nil] Logger instance, or nil to disable logging
    # @return [Logger] The normalized logger
    def logger=(value)
      @logger = value || Logger.new(IO::NULL)
    end

    # Validate the configuration
    #
    # @raise [ConfigurationError] if configuration is invalid
    # @return [void]
    def validate!
      validate_tracing_enabled!
      validate_connection_settings!
      validate_batching_settings!
      validate_sample_rate!
      validate_client_settings!
      validate_callable!(prompt_cache_observer, "prompt_cache_observer")
      validate_logger!
    end

    # Check whether the configuration can construct a client.
    #
    # This check is local. It does not validate credentials or network access.
    #
    # @return [Boolean] true when {#validate!} succeeds
    def valid?
      validate!
      true
    rescue ConfigurationError
      false
    end

    # Validate only settings consumed by tracing setup and export.
    #
    # @api private
    # @raise [ConfigurationError] if tracing configuration is invalid
    # @return [void]
    def validate_tracing!
      validate_tracing_enabled!
      validate_connection_settings!
      validate_batching_settings!
      validate_sample_rate!
      validate_callable!(should_export_span, "should_export_span")
      validate_callable!(mask, "mask")
      validate_callable!(mask_otel_spans, "mask_otel_spans")
      validate_metrics_reporter!
      validate_span_exporter!
      validate_logger!
    end

    # Validate settings needed while telemetry is disabled.
    #
    # @api private
    # @raise [ConfigurationError] if disabled-client configuration is invalid
    # @return [void]
    def validate_telemetry_disabled!
      validate_tracing_enabled!
      validate_logger!
    end

    # Check the effective tracing and scoring state.
    #
    # `OTEL_SDK_DISABLED=true` always disables telemetry. Otherwise,
    # `tracing_enabled` controls the result.
    #
    # @return [Boolean] true when tracing and scoring are enabled
    def telemetry_enabled?
      tracing_enabled && !@otel_sdk_disabled
    end

    # Normalize stale_ttl value
    #
    # Converts :indefinite to 1000 years in seconds for practical "never expire"
    # behavior while keeping the value finite for calculations.
    #
    # @return [Integer] Normalized stale TTL in seconds
    #
    # @example
    #   config.cache_stale_ttl = 300
    #   config.normalized_stale_ttl # => 300
    #
    #   config.cache_stale_ttl = :indefinite
    #   config.normalized_stale_ttl # => 31536000000
    def normalized_stale_ttl
      cache_stale_ttl == :indefinite ? INDEFINITE_SECONDS : cache_stale_ttl
    end

    # Set trace sampling rate.
    #
    # @param value [Numeric, String] Sampling rate from 0.0 to 1.0
    # @raise [ConfigurationError] if value is non-numeric or outside 0.0..1.0
    # @return [Float]
    def sample_rate=(value)
      @sample_rate = coerce_sample_rate(value)
    end

    private

    def initialize_client_defaults
      @timeout = env_integer("LANGFUSE_TIMEOUT") || DEFAULT_TIMEOUT
      @cache_ttl = DEFAULT_CACHE_TTL
      @cache_max_size = DEFAULT_CACHE_MAX_SIZE
      @cache_backend = DEFAULT_CACHE_BACKEND
      @cache_lock_timeout = DEFAULT_CACHE_LOCK_TIMEOUT
      @cache_stale_while_revalidate = DEFAULT_CACHE_STALE_WHILE_REVALIDATE
      @cache_stale_ttl = 0 # Default to 0 (SWR disabled, entries expire immediately after TTL)
      @cache_refresh_threads = DEFAULT_CACHE_REFRESH_THREADS
      @prompt_cache_observer = nil
      @tracing_async = DEFAULT_TRACING_ASYNC
      @batch_size = env_integer("LANGFUSE_FLUSH_AT") || DEFAULT_BATCH_SIZE
      @flush_interval = env_float("LANGFUSE_FLUSH_INTERVAL") || DEFAULT_FLUSH_INTERVAL
      @score_queue_capacity = DEFAULT_SCORE_QUEUE_CAPACITY
      @job_queue = DEFAULT_JOB_QUEUE
    end

    def initialize_logger
      self.logger = if env_true?("LANGFUSE_DEBUG")
                      Logger.new($stdout, level: Logger::DEBUG)
                    else
                      default_logger
                    end
    end

    def default_logger
      return Rails.logger if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      Logger.new($stdout, level: Logger::WARN)
    end

    def initialize_tracing_defaults
      @tracing_enabled = boolean_env("LANGFUSE_TRACING_ENABLED", default: DEFAULT_TRACING_ENABLED)
      @otel_sdk_disabled = ENV.fetch("OTEL_SDK_DISABLED", nil) == "true"
      @environment = env_value("LANGFUSE_TRACING_ENVIRONMENT")
      @release = env_value("LANGFUSE_RELEASE") || detect_release_from_ci_env
      self.sample_rate = env_value("LANGFUSE_SAMPLE_RATE") || DEFAULT_SAMPLE_RATE
      @should_export_span = nil
      @mask = nil
      @mask_otel_spans = nil
      @metrics_reporter = nil
      @span_exporter = nil
    end

    def validate_connection_settings!
      validate_required_string!("public_key", public_key)
      validate_required_string!("secret_key", secret_key)
      validate_base_url!
    end

    def validate_tracing_enabled!
      return if [true, false].include?(tracing_enabled)

      raise ConfigurationError, "tracing_enabled must be true or false"
    end

    def boolean_env(key, default:)
      value = env_value(key)
      return default if value.nil?
      return true if value.casecmp("true").zero?
      return false if value.casecmp("false").zero?

      raise ConfigurationError, "#{key} must be true or false"
    end

    def validate_batching_settings!
      unless batch_size.is_a?(Integer) && batch_size.positive?
        raise ConfigurationError, "batch_size must be a positive Integer"
      end

      validate_positive_number!("flush_interval", flush_interval)
    end

    def validate_client_settings!
      validate_positive_number!("timeout", timeout)
      validate_non_negative_number!("cache_ttl", cache_ttl)
      validate_positive_number!("cache_max_size", cache_max_size)
      validate_positive_number!("cache_lock_timeout", cache_lock_timeout)
      unless score_queue_capacity.is_a?(Integer) && score_queue_capacity.positive?
        raise ConfigurationError, "score_queue_capacity must be a positive Integer"
      end

      validate_swr_config!
      validate_cache_backend!
    end

    # Credentials reach the API as interpolated strings, so a value that only
    # answers #to_str would authenticate with its #to_s output instead.
    def validate_required_string!(name, value, empty_message: "#{name} is required")
      raise ConfigurationError, empty_message if value.nil?

      raise ConfigurationError, "#{name} must be a String" unless value.is_a?(String)

      raise ConfigurationError, empty_message if value.empty?
    end

    def validate_base_url!
      validate_required_string!("base_url", base_url, empty_message: "base_url cannot be empty")
      uri = URI.parse(base_url)
      return if %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?

      raise ConfigurationError, "base_url must be an absolute HTTP or HTTPS URL"
    rescue URI::InvalidURIError
      raise ConfigurationError, "base_url must be an absolute HTTP or HTTPS URL"
    end

    def validate_positive_number!(name, value)
      return if finite_ordered_number?(value) && value.positive?

      raise ConfigurationError, "#{name} must be positive"
    end

    def validate_non_negative_number!(name, value)
      return if finite_ordered_number?(value) && !value.negative?

      raise ConfigurationError, "#{name} must be non-negative"
    end

    def finite_ordered_number?(value)
      value.is_a?(Numeric) && value.respond_to?(:positive?) && value.finite?
    end

    def validate_cache_backend!
      valid_backends = %i[memory rails auto]
      unless valid_backends.include?(cache_backend)
        raise ConfigurationError,
              "cache_backend must be one of #{valid_backends.inspect}, got #{cache_backend.inspect}"
      end

      return unless cache_backend == :rails && cache_ttl.positive?
      return if RailsCacheAdapter.available?

      raise ConfigurationError,
            "Rails.cache is not available. Rails cache backend requires Rails with a configured cache store."
    end

    def validate_callable!(value, name)
      return if value.nil? || value.respond_to?(:call)

      raise ConfigurationError, "#{name} must respond to #call"
    end

    def validate_logger!
      missing_methods = LOGGER_METHODS.reject { |method_name| logger.respond_to?(method_name) }
      return if missing_methods.empty?

      required_methods = LOGGER_METHODS.map { |method_name| "##{method_name}" }.join(", ")
      raise ConfigurationError, "logger must respond to #{required_methods}"
    end

    def validate_metrics_reporter!
      return if metrics_reporter.nil?

      missing_methods = METRICS_REPORTER_METHODS.reject do |method_name|
        metrics_reporter.respond_to?(method_name)
      end
      return if missing_methods.empty?

      required_methods = METRICS_REPORTER_METHODS.map { |method_name| "##{method_name}" }.join(", ")
      raise ConfigurationError, "metrics_reporter must respond to #{required_methods}"
    end

    def validate_span_exporter!
      return if span_exporter.nil?

      missing_methods = SPAN_EXPORTER_METHODS.reject do |method_name|
        span_exporter.respond_to?(method_name)
      end
      return if missing_methods.empty?

      required_methods = SPAN_EXPORTER_METHODS.map { |method_name| "##{method_name}" }.join(", ")
      raise ConfigurationError, "span_exporter must respond to #{required_methods}"
    end

    def validate_swr_config!
      validate_swr_stale_ttl!
      validate_refresh_threads!
    end

    def validate_swr_stale_ttl!
      # Check if SWR is enabled but stale_ttl is nil
      if cache_stale_while_revalidate && cache_stale_ttl.nil?
        raise ConfigurationError,
              "cache_stale_ttl cannot be nil when cache_stale_while_revalidate is enabled. " \
              "Set it to cache_ttl for a logical default, or use :indefinite for never-expiring cache."
      end

      # Validate that cache_stale_ttl is not nil (unless already caught by SWR check)
      if cache_stale_ttl.nil?
        raise ConfigurationError,
              "cache_stale_ttl must be non-negative or :indefinite"
      end

      return if cache_stale_ttl == :indefinite
      return if finite_ordered_number?(cache_stale_ttl) && !cache_stale_ttl.negative?

      raise ConfigurationError,
            "cache_stale_ttl must be non-negative or :indefinite"
    end

    def validate_refresh_threads!
      validate_positive_number!("cache_refresh_threads", cache_refresh_threads)
    end

    def validate_sample_rate!
      return if sample_rate.is_a?(Numeric) && sample_rate.between?(0.0, 1.0)

      raise ConfigurationError, "sample_rate must be between 0.0 and 1.0"
    end

    def detect_release_from_ci_env
      COMMON_RELEASE_ENV_KEYS.each do |key|
        value = env_value(key)
        return value if value
      end

      nil
    end

    def env_value(key)
      value = ENV.fetch(key, nil)
      return nil if value.nil? || value.empty?

      value
    end

    def env_integer(key)
      value = env_value(key)
      return nil unless value

      Integer(value, 10)
    rescue ArgumentError, TypeError
      raise ConfigurationError, "#{key} must be an integer"
    end

    def env_float(key)
      value = env_value(key)
      return nil unless value

      Float(value)
    rescue ArgumentError, TypeError
      raise ConfigurationError, "#{key} must be numeric"
    end

    def env_true?(key)
      env_value(key)&.casecmp?("true") || false
    end

    def coerce_sample_rate(value)
      numeric_value = if value.is_a?(Numeric)
                        value.to_f
                      elsif value.is_a?(String)
                        Float(value)
                      else
                        raise ConfigurationError, "sample_rate must be numeric"
                      end

      return numeric_value if numeric_value.between?(0.0, 1.0)

      raise ConfigurationError, "sample_rate must be between 0.0 and 1.0"
    rescue ArgumentError, RangeError, TypeError
      raise ConfigurationError, "sample_rate must be numeric"
    end
  end
  # rubocop:enable Metrics/ClassLength
end
