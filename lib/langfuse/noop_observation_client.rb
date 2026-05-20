# frozen_string_literal: true

module Langfuse
  # No-op owner for module-level observations when tracing config is incomplete.
  #
  # @api private
  class NoopObservationClient
    include ObservationMethods

    # @return [Config] configuration used for masking and logging
    attr_reader :config

    # @param config [Config] global configuration snapshot
    # @return [NoopObservationClient]
    def initialize(config)
      @config = config
      @tracer_provider = OpenTelemetry::Trace::TracerProvider.new
    end

    # @param trace_id [String] ignored trace ID
    # @return [nil]
    def trace_url(_trace_id)
      nil
    end

    # @return [nil]
    def create_score(**)
      nil
    end

    # @return [nil]
    def flush_scores
      nil
    end

    # @return [nil]
    def force_flush(**_kwargs)
      nil
    end

    # @return [nil]
    def shutdown(**_kwargs)
      nil
    end

    private

    def observation_tracer
      @tracer_provider.tracer(LANGFUSE_TRACER_NAME, Langfuse::VERSION)
    end

    def observation_mask
      config.mask
    end

    def observation_owner
      self
    end
  end
end
