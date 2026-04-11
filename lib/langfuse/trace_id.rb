# frozen_string_literal: true

require "digest"

module Langfuse
  # Deterministic and random trace/observation ID generation.
  #
  # Mirrors the Python and JS SDK helpers so the same seed produces the same
  # trace ID across all three SDKs. This lets callers correlate Langfuse traces
  # with external system identifiers (database primary keys, request IDs, etc.)
  # and score or reference traces later without having to persist the generated
  # Langfuse ID.
  #
  # @example Deterministic from an external ID
  #   trace_id = Langfuse::TraceId.create(seed: "order-12345")
  #   Langfuse.observe("process-order", trace_id: trace_id) { |span| ... }
  #   Langfuse.create_score(name: "quality", value: 0.9, trace_id: trace_id)
  #
  # @example Random (no seed)
  #   trace_id = Langfuse::TraceId.create
  module TraceId
    TRACE_ID_PATTERN = /\A[0-9a-f]{32}\z/
    OBSERVATION_ID_PATTERN = /\A[0-9a-f]{16}\z/
    INVALID_TRACE_ID = ("0" * 32)
    INVALID_OBSERVATION_ID = ("0" * 16)

    class << self
      # Generate a W3C trace ID (32 lowercase hex chars).
      #
      # With no seed, delegates to OpenTelemetry's random trace ID generator.
      # With a seed, takes the first 16 bytes of SHA-256(seed) so the same
      # input always produces the same trace ID.
      #
      # @param seed [String, nil] Optional seed for deterministic generation
      # @return [String] 32-character lowercase hex trace ID
      def create(seed: nil)
        return OpenTelemetry::Trace.generate_trace_id.unpack1("H*") if seed.nil?

        Digest::SHA256.digest(seed.to_s)[0, 16].unpack1("H*")
      end

      # Generate a W3C span ID (16 lowercase hex chars).
      #
      # With no seed, delegates to OpenTelemetry's random span ID generator.
      # With a seed, takes the first 8 bytes of SHA-256(seed).
      #
      # @param seed [String, nil] Optional seed for deterministic generation
      # @return [String] 16-character lowercase hex observation ID
      def create_observation_id(seed: nil)
        return OpenTelemetry::Trace.generate_span_id.unpack1("H*") if seed.nil?

        Digest::SHA256.digest(seed.to_s)[0, 8].unpack1("H*")
      end

      # @param trace_id [Object] Value to validate
      # @return [Boolean] true when the value is a 32-char lowercase hex string
      #   that is not the all-zero W3C "invalid" trace ID
      def valid?(trace_id)
        return false unless trace_id.is_a?(String) && TRACE_ID_PATTERN.match?(trace_id)

        # W3C trace-context: the all-zero trace ID is reserved as "invalid"
        # and OpenTelemetry treats it as an invalid SpanContext.
        trace_id != INVALID_TRACE_ID
      end

      # @param id [Object] Value to validate
      # @return [Boolean] true when the value is a 16-char lowercase hex string
      #   that is not the all-zero W3C "invalid" span ID
      def valid_observation_id?(id)
        return false unless id.is_a?(String) && OBSERVATION_ID_PATTERN.match?(id)

        # W3C trace-context: the all-zero span ID is reserved as "invalid".
        id != INVALID_OBSERVATION_ID
      end

      # Build a sampled OpenTelemetry SpanContext carrying the given hex trace ID.
      #
      # Passed as `parent_span_context:` to {Langfuse.start_observation}, this
      # forces the next span onto the provided trace. A SpanContext also needs
      # a span_id, so a random one is generated; it is never persisted — only
      # the trace_id is consumed by the child span that gets created. This
      # mirrors the Python SDK's `create_trace_id` / SpanContext wiring.
      #
      # @param trace_id [String] 32-character lowercase hex trace ID
      # @return [OpenTelemetry::Trace::SpanContext] sampled span context
      # @raise [ArgumentError] if `trace_id` is not a valid trace ID
      def to_span_context(trace_id)
        raise ArgumentError, "Invalid trace_id: #{trace_id.inspect}" unless valid?(trace_id)

        OpenTelemetry::Trace::SpanContext.new(
          trace_id: [trace_id].pack("H*"),
          span_id: OpenTelemetry::Trace.generate_span_id,
          trace_flags: OpenTelemetry::Trace::TraceFlags::SAMPLED,
          remote: false
        )
      end
    end
  end
end
