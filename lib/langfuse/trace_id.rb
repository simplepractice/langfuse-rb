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
  # Also serves as the OpenTelemetry ID generator installed on Langfuse's
  # TracerProvider (`id_generator: TraceId`) — see {.generate_trace_id}.
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
    PINNED_TRACE_ID_KEY = :langfuse_pinned_trace_id

    private_constant :TRACE_ID_PATTERN, :INVALID_TRACE_ID, :PINNED_TRACE_ID_KEY

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

      # Runs the block with {.generate_trace_id} pinned to +trace_id+.
      #
      # Fiber-local (`Fiber[]`, Ruby 3.2+) — `Thread.current[]=` looks
      # equivalent but doesn't inherit into a fiber spawned mid-call, which
      # breaks under fiber-based schedulers (e.g. `async`, Falcon). Restores
      # rather than clears the previous value, so nested calls on the same
      # fiber stay correct.
      #
      # Validates before touching Fiber storage — validating inside the
      # `ensure` would restore a captured-too-late `previous` of +nil+,
      # clobbering an outer call's pinned trace ID.
      #
      # @param trace_id [String] 32-char lowercase hex trace ID
      # @return [Object] the block's return value
      # @raise [ArgumentError] if trace_id is invalid
      # @api private
      def pin_generation_to(trace_id)
        raise ArgumentError, "Invalid trace_id: #{trace_id.inspect}" unless valid?(trace_id)

        previous_trace_id = Fiber[PINNED_TRACE_ID_KEY]

        # Convert a hex trace ID to the raw 16-byte form OpenTelemetry uses internally.
        Fiber[PINNED_TRACE_ID_KEY] = [trace_id].pack("H*")

        begin
          yield
        ensure
          Fiber[PINNED_TRACE_ID_KEY] = previous_trace_id
        end
      end

      # OpenTelemetry ID generator contract (see `TracerProvider.new(id_generator:)`
      # in otel_setup.rb). OTel only ever consults this for spans with no valid
      # parent (see `Langfuse.create_root_span`, which forces this by starting the span
      # with a context whose "current span" slot is `Span::INVALID`); spans with a real
      # or synthetic parent take their trace ID from that parent's context instead. Falls
      # back to OpenTelemetry's own random generator whenever
      # {.pin_generation_to} isn't active, so untouched root spans are
      # unaffected.
      #
      # @api private
      def generate_trace_id
        Fiber[PINNED_TRACE_ID_KEY] || OpenTelemetry::Trace.generate_trace_id
      end

      # @api private
      def generate_span_id
        OpenTelemetry::Trace.generate_span_id
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
    end
  end
end
