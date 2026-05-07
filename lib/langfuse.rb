# frozen_string_literal: true

require_relative "langfuse/version"
require_relative "langfuse/types"

# Langfuse Ruby SDK
#
# Official Ruby SDK for Langfuse, providing LLM tracing, observability,
# and prompt management capabilities.
#
# @example Global configuration (Rails initializer)
#   Langfuse.configure do |config|
#     config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
#     config.secret_key = ENV['LANGFUSE_SECRET_KEY']
#     config.cache_ttl = 120
#   end
#
# @example Using the global client
#   client = Langfuse.client
#   prompt = client.get_prompt("greeting")
#
module Langfuse
  # Base error class for all Langfuse SDK errors
  class Error < StandardError; end

  # Raised when Langfuse configuration is invalid or incomplete
  class ConfigurationError < Error; end

  # Raised when a Langfuse API request fails
  class ApiError < Error; end

  # Raised when a requested resource is not found (HTTP 404)
  class NotFoundError < ApiError; end

  # Raised when API authentication fails (HTTP 401)
  class UnauthorizedError < ApiError; end

  # Default timeout (in seconds) for flushing traces during experiment runs.
  FLUSH_TIMEOUT = 5
end

require_relative "langfuse/config"
require_relative "langfuse/cache_constants"
require_relative "langfuse/prompt_cache"
require_relative "langfuse/prompt_fetch_result"
require_relative "langfuse/rails_cache_adapter"
require_relative "langfuse/prompt_cache_coordinator"
require_relative "langfuse/cache_warmer"
require_relative "langfuse/prompt_cache_events"
require_relative "langfuse/api_client"
require_relative "langfuse/span_filter"
require_relative "langfuse/sampling"
require_relative "langfuse/otel_setup"
require_relative "langfuse/masking"
require_relative "langfuse/otel_attributes"
require_relative "langfuse/propagation"
require_relative "langfuse/span_processor"
require_relative "langfuse/observations"
require_relative "langfuse/trace_id"
require_relative "langfuse/observation_methods"
require_relative "langfuse/score_client"
require_relative "langfuse/prompt_renderer"
require_relative "langfuse/text_prompt_client"
require_relative "langfuse/chat_prompt_client"
require_relative "langfuse/timestamp_parser"
require_relative "langfuse/evaluation"
require_relative "langfuse/experiment_item"
require_relative "langfuse/item_result"
require_relative "langfuse/experiment_result"
require_relative "langfuse/traced_execution"
require_relative "langfuse/dataset_client"
require_relative "langfuse/dataset_item_client"
require_relative "langfuse/experiment_runner"
require_relative "langfuse/client"

# rubocop:disable Metrics/ModuleLength
module Langfuse
  class << self
    include ObservationMethods

    # @param configuration [Config] the global configuration object
    attr_writer :configuration

    # Returns the global configuration object
    #
    # @return [Config] the global configuration
    def configuration
      @configuration ||= Config.new
    end

    # Configure Langfuse globally
    #
    # @yield [Config] the configuration object
    # @return [Config] the configured configuration
    #
    # @example
    #   Langfuse.configure do |config|
    #     config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
    #     config.secret_key = ENV['LANGFUSE_SECRET_KEY']
    #   end
    def configure
      yield(configuration)
      configuration
    end

    # Returns the global singleton client
    #
    # @return [Client] the global client instance
    def client
      @client ||= Client.new(configuration)
    end

    # Return Langfuse's internal tracer provider for explicit global OpenTelemetry installation.
    #
    # @return [OpenTelemetry::SDK::Trace::TracerProvider]
    # @raise [ConfigurationError] if tracing is not fully configured
    #
    # @example
    #   Langfuse.configure do |config|
    #     config.public_key = ENV["LANGFUSE_PUBLIC_KEY"]
    #     config.secret_key = ENV["LANGFUSE_SECRET_KEY"]
    #   end
    #
    #   OpenTelemetry.tracer_provider = Langfuse.tracer_provider
    def tracer_provider
      unless tracing_config_ready?
        raise ConfigurationError,
              "Langfuse tracing is disabled until public_key, secret_key, and base_url are configured."
      end

      OtelSetup.setup(configuration) unless OtelSetup.initialized?
      OtelSetup.tracer_provider
    end

    # Shutdown Langfuse and flush any pending traces and scores
    #
    # Call this when shutting down your application to ensure
    # all traces and scores are sent to Langfuse.
    #
    # @param timeout [Integer] Timeout in seconds
    # @return [void]
    #
    # @example In a Rails initializer or shutdown hook
    #   at_exit { Langfuse.shutdown }
    #
    def shutdown(timeout: 30)
      @client&.shutdown(timeout: timeout)
      OtelSetup.shutdown(timeout: timeout)
    end

    # Force flush all pending traces
    #
    # @param timeout [Integer] Timeout in seconds
    # @return [void]
    def force_flush(timeout: 30)
      OtelSetup.force_flush(timeout: timeout)
    end

    # Propagate trace-level attributes to all spans created within this context.
    #
    # This method sets attributes on the currently active span AND automatically
    # propagates them to all new child spans created within the block. This is the
    # recommended way to set trace-level attributes like user_id, session_id, and metadata
    # dimensions that should be consistently applied across all observations in a trace.
    #
    # **IMPORTANT**: Call this as early as possible within your trace/workflow. Only the
    # currently active span and spans created after entering this context will have these
    # attributes. Pre-existing spans will NOT be retroactively updated.
    #
    # @param user_id [String, nil] User identifier (≤200 characters)
    # @param session_id [String, nil] Session identifier (≤200 characters)
    # @param metadata [Hash<String, String>, nil] Additional metadata (all values ≤200 characters)
    # @param version [String, nil] Version identifier (≤200 characters)
    # @param tags [Array<String>, nil] List of tags (each ≤200 characters)
    # @param as_baggage [Boolean] If true, propagates via OpenTelemetry baggage for cross-service propagation
    # @yield Block within which attributes are propagated
    # @return [Object] The result of the block
    #
    # @example Basic usage
    #   Langfuse.propagate_attributes(user_id: "user_123", session_id: "session_abc") do
    #     Langfuse.observe("operation") do |span|
    #       # Current span has user_id and session_id
    #       span.start_observation("child") do |child|
    #         # Child span inherits user_id and session_id
    #       end
    #     end
    #   end
    #
    # @example With metadata and tags
    #   Langfuse.propagate_attributes(
    #     user_id: "user_123",
    #     metadata: { environment: "production", region: "us-east" },
    #     tags: ["api", "v2"]
    #   ) do
    #     # All spans inherit these attributes
    #   end
    #
    # @example Cross-service propagation
    #   Langfuse.propagate_attributes(
    #     user_id: "user_123",
    #     as_baggage: true
    #   ) do
    #     # Attributes propagate via HTTP headers
    #   end
    def propagate_attributes(user_id: nil, session_id: nil, metadata: nil, version: nil, tags: nil,
                             as_baggage: false, &)
      Propagation.propagate_attributes(
        user_id: user_id,
        session_id: session_id,
        metadata: metadata,
        version: version,
        tags: tags,
        as_baggage: as_baggage,
        &
      )
    end

    # Create a score event and queue it for batching
    #
    # @param name [String] Score name (required)
    # @param value [Numeric, Integer, String] Score value (type depends on data_type)
    # @param id [String, nil] Score ID
    # @param trace_id [String, nil] Trace ID to associate with the score
    # @param session_id [String, nil] Session ID to associate with the score
    # @param observation_id [String, nil] Observation ID to associate with the score
    # @param comment [String, nil] Optional comment
    # @param metadata [Hash, nil] Optional metadata hash
    # @param environment [String, nil] Optional environment
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical)
    # @param dataset_run_id [String, nil] Optional dataset run ID to associate with the score
    # @param config_id [String, nil] Optional score config ID
    # @return [void]
    # @raise [ArgumentError] if validation fails
    #
    # @example Numeric score
    #   Langfuse.create_score(name: "quality", value: 0.85, trace_id: "abc123")
    #
    # @example Boolean score
    #   Langfuse.create_score(name: "passed", value: true, trace_id: "abc123", data_type: :boolean)
    #
    # @example Categorical score
    #   Langfuse.create_score(name: "category", value: "high", trace_id: "abc123", data_type: :categorical)
    # rubocop:disable Metrics/ParameterLists
    def create_score(name:, value:, id: nil, trace_id: nil, session_id: nil, observation_id: nil, comment: nil,
                     metadata: nil, environment: nil, data_type: :numeric, dataset_run_id: nil, config_id: nil)
      client.create_score(
        name: name,
        value: value,
        id: id,
        trace_id: trace_id,
        session_id: session_id,
        observation_id: observation_id,
        comment: comment,
        metadata: metadata,
        environment: environment,
        data_type: data_type,
        dataset_run_id: dataset_run_id,
        config_id: config_id
      )
    end
    # rubocop:enable Metrics/ParameterLists

    # Create a score for the currently active observation (from OTel span)
    #
    # Extracts observation_id and trace_id from the active OpenTelemetry span.
    #
    # @param name [String] Score name (required)
    # @param value [Numeric, Integer, String] Score value
    # @param comment [String, nil] Optional comment
    # @param metadata [Hash, nil] Optional metadata hash
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical)
    # @return [void]
    # @raise [ArgumentError] if no active span or validation fails
    #
    # @example
    #   Langfuse.observe("operation") do |obs|
    #     Langfuse.score_active_observation(name: "accuracy", value: 0.92)
    #   end
    def score_active_observation(name:, value:, comment: nil, metadata: nil, data_type: :numeric)
      client.score_active_observation(
        name: name,
        value: value,
        comment: comment,
        metadata: metadata,
        data_type: data_type
      )
    end

    # Create a score for the currently active trace (from OTel span)
    #
    # Extracts trace_id from the active OpenTelemetry span.
    #
    # @param name [String] Score name (required)
    # @param value [Numeric, Integer, String] Score value
    # @param comment [String, nil] Optional comment
    # @param metadata [Hash, nil] Optional metadata hash
    # @param data_type [Symbol] Data type (:numeric, :boolean, :categorical)
    # @return [void]
    # @raise [ArgumentError] if no active span or validation fails
    #
    # @example
    #   Langfuse.observe("operation") do |obs|
    #     Langfuse.score_active_trace(name: "overall_quality", value: 5)
    #   end
    def score_active_trace(name:, value:, comment: nil, metadata: nil, data_type: :numeric)
      client.score_active_trace(
        name: name,
        value: value,
        comment: comment,
        metadata: metadata,
        data_type: data_type
      )
    end

    # Force flush all queued score events
    #
    # Sends all queued score events to the API immediately.
    #
    # @return [void]
    #
    # @example
    #   Langfuse.flush_scores
    def flush_scores
      client.flush_scores if @client
    end

    # Generate a trace ID (deterministic when seeded, random otherwise).
    #
    # Use this to correlate Langfuse traces with external identifiers. The
    # same seed always produces the same trace ID across the Ruby, Python,
    # and JS SDKs (SHA-256 of the seed, first 16 bytes, as 32 hex chars).
    #
    # @note Avoid PII or secrets as seeds. See {TraceId.create} for details.
    # @param seed [String, nil] Optional deterministic seed
    # @return [String] 32-character lowercase hex trace ID
    # @raise [ArgumentError] if seed is not nil and not a String
    #
    # @example
    #   trace_id = Langfuse.create_trace_id(seed: "order-12345")
    #   Langfuse.observe("process", trace_id: trace_id) { |span| ... }
    def create_trace_id(seed: nil)
      TraceId.create(seed: seed)
    end

    # Reset global configuration and client (useful for testing)
    #
    # @return [void]
    def reset!
      client.shutdown if @client
      OtelSetup.shutdown(timeout: 5) if OtelSetup.initialized?
      @configuration = nil
      @client = nil
      @noop_tracer = nil
      @tracing_disabled_warning_emitted = false
    rescue StandardError
      # Ignore shutdown errors during reset (e.g., in tests)
      @configuration = nil
      @client = nil
      @noop_tracer = nil
      @tracing_disabled_warning_emitted = false
    end

    private

    def observation_tracer
      otel_tracer
    end

    def observation_mask
      configuration.mask
    end

    def observation_client
      nil
    end

    # Gets the OpenTelemetry tracer for Langfuse
    #
    # @return [OpenTelemetry::SDK::Trace::Tracer] The OTel tracer
    def otel_tracer
      return tracer_provider.tracer(LANGFUSE_TRACER_NAME, Langfuse::VERSION) if setup_tracing_if_ready

      warn_tracing_disabled_once
      noop_tracer
    end

    # rubocop:disable Naming/PredicateMethod
    def setup_tracing_if_ready
      return true if OtelSetup.initialized?
      return false unless tracing_config_ready?

      OtelSetup.setup(configuration)
      true
    end
    # rubocop:enable Naming/PredicateMethod

    def tracing_config_ready?
      configured?(configuration.public_key) &&
        configured?(configuration.secret_key) &&
        configured?(configuration.base_url)
    end

    def configured?(value)
      !value.nil? && !value.empty?
    end

    def warn_tracing_disabled_once
      return if @tracing_disabled_warning_emitted

      tracing_warning_mutex.synchronize do
        return if @tracing_disabled_warning_emitted

        configuration.logger.warn(
          "Langfuse tracing is disabled until public_key, secret_key, and base_url are configured."
        )
        @tracing_disabled_warning_emitted = true
      end
    end

    def tracing_warning_mutex
      @tracing_warning_mutex ||= Mutex.new
    end

    def noop_tracer
      @noop_tracer ||= OpenTelemetry::Trace::TracerProvider.new.tracer(LANGFUSE_TRACER_NAME, Langfuse::VERSION)
    end
  end
end
# rubocop:enable Metrics/ModuleLength
