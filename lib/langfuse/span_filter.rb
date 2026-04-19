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

  # rubocop:disable Naming/PredicateMethod, Naming/PredicatePrefix
  class << self
    # Return whether the span was created by Langfuse's tracer.
    #
    # @param span [#instrumentation_scope] Span or span data to inspect
    # @return [Boolean]
    def is_langfuse_span(span)
      instrumentation_scope_name(span) == LANGFUSE_TRACER_NAME
    end

    # Return whether the span contains `gen_ai.*` attributes.
    #
    # @param span [#attributes] Span or span data to inspect
    # @return [Boolean]
    def is_genai_span(span)
      attributes = span.attributes
      return false unless attributes

      attributes.keys.any? { |key| key.is_a?(String) && key.start_with?("gen_ai.") }
    end

    # Return whether the span came from a known LLM instrumentation scope.
    #
    # @param span [#instrumentation_scope] Span or span data to inspect
    # @return [Boolean]
    def is_known_llm_instrumentor(span)
      scope_name = instrumentation_scope_name(span)
      return false unless scope_name

      KNOWN_LLM_INSTRUMENTATION_SCOPE_PREFIXES.any? do |prefix|
        matches_scope_prefix?(scope_name, prefix)
      end
    end

    # Return whether a span should be exported when no custom filter is configured.
    #
    # @param span [#instrumentation_scope, #attributes] Span or span data to inspect
    # @return [Boolean]
    def is_default_export_span(span)
      is_langfuse_span(span) || is_genai_span(span) || is_known_llm_instrumentor(span)
    end

    private

    def instrumentation_scope_name(span)
      span.instrumentation_scope&.name
    end

    def matches_scope_prefix?(scope_name, prefix)
      scope_name == prefix || scope_name.start_with?("#{prefix}.")
    end
  end
  # rubocop:enable Naming/PredicateMethod, Naming/PredicatePrefix
end
