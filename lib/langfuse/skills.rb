# frozen_string_literal: true

require "json"
require "opentelemetry/context"

module Langfuse
  # Skill availability is local context, never cross-service baggage.
  # @api private
  module Skills
    AVAILABLE_CONTEXT_KEY = OpenTelemetry::Context.create_key("langfuse_skills_available")
    ATTACH_CONTEXT_KEY = OpenTelemetry::Context.create_key("langfuse_attach_skills")
    private_constant :AVAILABLE_CONTEXT_KEY, :ATTACH_CONTEXT_KEY

    def self.serialize(value, logger: Langfuse.configuration.logger)
      return nil if value.nil?

      JSON.generate(value).freeze
    rescue StandardError
      logger.warn("Failed to serialize available skills. Dropping value.")
      nil
    end

    def self.propagate(context, skills_available:, attach_skills:)
      serialized = serialize(skills_available)
      unless serialized.nil?
        context = context.set_value(AVAILABLE_CONTEXT_KEY, serialized)
        span = OpenTelemetry::Trace.current_span
        span.set_attribute(OtelAttributes::OBSERVATION_SKILLS_AVAILABLE, serialized) if span.recording?
      end
      context = context.set_value(ATTACH_CONTEXT_KEY, attach_skills) if [true, false].include?(attach_skills)
      context
    end

    def self.attributes(context, catalog: nil)
      value = context.value(AVAILABLE_CONTEXT_KEY)
      value = catalog if value.nil? && context.value(ATTACH_CONTEXT_KEY) == true
      return {} if value.nil?

      { OtelAttributes::OBSERVATION_SKILLS_AVAILABLE => value }
    end
  end
end
