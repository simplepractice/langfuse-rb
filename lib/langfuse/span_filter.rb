# frozen_string_literal: true

module Langfuse
  # Instrumentation scope name used by module-level Langfuse tracing.
  LANGFUSE_TRACER_NAME = "langfuse-rb"

  # Conservative allowlist of instrumentation scope prefixes that clearly belong to LLM workflows.
  KNOWN_LLM_INSTRUMENTATION_SCOPE_PREFIXES = [
    LANGFUSE_TRACER_NAME,
    "agent_framework",
    "ai",
    "haystack",
    "langsmith",
    "litellm",
    "openinference",
    "opentelemetry.instrumentation.anthropic",
    "strands-agents",
    "vllm"
  ].freeze

  # Matched per span in the export path, so avoid allocating the dotted form each call.
  KNOWN_LLM_INSTRUMENTATION_SCOPE_DOTTED_PREFIXES =
    KNOWN_LLM_INSTRUMENTATION_SCOPE_PREFIXES.map { |prefix| "#{prefix}." }.freeze
  private_constant :KNOWN_LLM_INSTRUMENTATION_SCOPE_DOTTED_PREFIXES

  class << self
    # Return whether the span was created by Langfuse's tracer.
    #
    # @param span [#instrumentation_scope] Span or span data to inspect
    # @return [Boolean]
    def langfuse_span?(span)
      instrumentation_scope_name(span) == LANGFUSE_TRACER_NAME
    end

    # Return whether the span contains `gen_ai.*` attributes.
    #
    # @param span [#attributes] Span or span data to inspect
    # @return [Boolean]
    def genai_span?(span)
      attributes = span.attributes
      return false unless attributes

      attributes.keys.any? { |key| key.is_a?(String) && key.start_with?("gen_ai.") }
    end

    # Return whether the span came from a known LLM instrumentation scope.
    #
    # @param span [#instrumentation_scope] Span or span data to inspect
    # @return [Boolean]
    def known_llm_instrumentor?(span)
      scope_name = instrumentation_scope_name(span)
      return false unless scope_name

      return true if KNOWN_LLM_INSTRUMENTATION_SCOPE_PREFIXES.include?(scope_name)

      KNOWN_LLM_INSTRUMENTATION_SCOPE_DOTTED_PREFIXES.any? do |dotted_prefix|
        scope_name.start_with?(dotted_prefix)
      end
    end

    # Return whether a span should be exported when no custom filter is configured.
    #
    # @param span [#instrumentation_scope, #attributes] Span or span data to inspect
    # @return [Boolean]
    def default_export_span?(span)
      langfuse_span?(span) || genai_span?(span) || known_llm_instrumentor?(span)
    end

    # Cross-SDK parity keeps the `is_*` names public for compatibility.
    alias is_langfuse_span langfuse_span?
    alias is_genai_span genai_span?
    alias is_known_llm_instrumentor known_llm_instrumentor?
    alias is_default_export_span default_export_span?

    private

    def instrumentation_scope_name(span)
      span.instrumentation_scope&.name
    end
  end
end
