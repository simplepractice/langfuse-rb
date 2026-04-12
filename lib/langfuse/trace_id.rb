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
    INVALID_TRACE_ID = ("0" * 32)

    private_constant :TRACE_ID_PATTERN, :INVALID_TRACE_ID

    class << self
      # Generate a W3C trace ID (32 lowercase hex chars).
      #
      # With no seed, delegates to OpenTelemetry's random trace ID generator.
      # With a seed, takes the first 16 bytes of SHA-256(seed) so the same
      # input always produces the same trace ID.
      #
      # @note Avoid passing PII, secrets, or credentials as seeds — the raw seed
      #   value appears in application code and may leak through logs/backtraces.
      #   Use stable external identifiers (database PKs, UUIDs, request IDs).
      # @param seed [String, nil] Optional seed for deterministic generation.
      #   Must be a String if provided; non-String values raise ArgumentError
      #   for cross-SDK parity (Python/JS both reject non-strings).
      # @return [String] 32-character lowercase hex trace ID
      # @raise [ArgumentError] if seed is not nil and not a String
      def create(seed: nil)
        return OpenTelemetry::Trace.generate_trace_id.unpack1("H*") if seed.nil?

        Digest::SHA256.digest(validate_seed!(seed))[0, 16].unpack1("H*")
      end

      private

      # @api private
      def validate_seed!(seed)
        raise ArgumentError, "seed must be a String, got #{seed.class}" unless seed.is_a?(String)

        # ASCII-8BIT strings (binary) often already hold valid UTF-8 bytes
        # but can't be transcoded — re-tag them instead.
        return seed.dup.force_encoding("UTF-8") if seed.encoding == Encoding::ASCII_8BIT

        seed.encode("UTF-8")
      end

      # @api private
      def valid?(trace_id)
        return false unless trace_id.is_a?(String) && TRACE_ID_PATTERN.match?(trace_id)

        trace_id != INVALID_TRACE_ID
      end

      # Build a sampled OpenTelemetry SpanContext carrying the given hex trace ID.
      #
      # A random span_id is generated as a placeholder — only the trace_id is
      # consumed by the child span that gets created.
      #
      # @api private
      def to_span_context(trace_id)
        raise ArgumentError, "Invalid trace_id: #{trace_id.inspect}" unless valid?(trace_id)

        OpenTelemetry::Trace::SpanContext.new(
          trace_id: [trace_id].pack("H*"),
          span_id: OpenTelemetry::Trace.generate_span_id,
          trace_flags: OpenTelemetry::Trace::TraceFlags::SAMPLED,
          # Cross-SDK parity: Python uses is_remote=False (_create_remote_parent_span).
          # Changing this would alter ParentBased sampler behavior across SDKs.
          remote: false
        )
      end
    end
  end
end
