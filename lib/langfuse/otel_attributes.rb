# frozen_string_literal: true

module Langfuse
  # Serialization layer that converts Langfuse domain models to OpenTelemetry span attributes format
  #
  # This module provides methods to convert user-friendly Langfuse attribute objects
  # into the internal OpenTelemetry attribute format required by the span processor.
  #
  # @example Converting trace attributes
  #   attrs = Langfuse::Types::TraceAttributes.new(
  #     name: "user-checkout-flow",
  #     user_id: "user-123",
  #     tags: ["checkout", "payment"],
  #     metadata: { version: "2.1.0" }
  #   )
  #   otel_attrs = Langfuse::OtelAttributes.create_trace_attributes(attrs)
  #   span.set_attributes(otel_attrs)
  #
  # @example Converting observation attributes
  #   attrs = Langfuse::Types::GenerationAttributes.new(
  #     model: "gpt-4",
  #     input: { messages: [...] },
  #     usage_details: { prompt_tokens: 100 }
  #   )
  #   otel_attrs = Langfuse::OtelAttributes.create_observation_attributes("generation", attrs)
  #   span.set_attributes(otel_attrs)
  #
  # rubocop:disable Metrics/ModuleLength
  module OtelAttributes
    # Trace attributes
    TRACE_NAME = "langfuse.trace.name"
    # TRACE_USER_ID and TRACE_SESSION_ID are without langfuse prefix
    # because they follow OpenTelemetry semantic conventions
    TRACE_USER_ID = "user.id"
    TRACE_SESSION_ID = "session.id"
    TRACE_INPUT = "langfuse.trace.input"
    TRACE_OUTPUT = "langfuse.trace.output"
    TRACE_METADATA = "langfuse.trace.metadata"
    TRACE_TAGS = "langfuse.trace.tags"
    TRACE_PUBLIC = "langfuse.trace.public"

    # Observation attributes
    OBSERVATION_TYPE = "langfuse.observation.type"
    OBSERVATION_INPUT = "langfuse.observation.input"
    OBSERVATION_OUTPUT = "langfuse.observation.output"
    OBSERVATION_METADATA = "langfuse.observation.metadata"
    OBSERVATION_LEVEL = "langfuse.observation.level"
    OBSERVATION_STATUS_MESSAGE = "langfuse.observation.status_message"
    OBSERVATION_MODEL = "langfuse.observation.model.name"
    OBSERVATION_MODEL_PARAMETERS = "langfuse.observation.model.parameters"
    OBSERVATION_USAGE_DETAILS = "langfuse.observation.usage_details"
    OBSERVATION_COST_DETAILS = "langfuse.observation.cost_details"
    OBSERVATION_PROMPT_NAME = "langfuse.observation.prompt.name"
    OBSERVATION_PROMPT_VERSION = "langfuse.observation.prompt.version"
    OBSERVATION_COMPLETION_START_TIME = "langfuse.observation.completion_start_time"

    # Common attributes
    VERSION = "langfuse.version"
    RELEASE = "langfuse.release"
    ENVIRONMENT = "langfuse.environment"

    # Creates OpenTelemetry attributes from Langfuse trace attributes
    #
    # Converts user-friendly trace attributes into the internal OpenTelemetry
    # attribute format required by the span processor.
    #
    # @param attrs [Types::TraceAttributes, Hash] Trace attributes object or hash
    # @return [Hash] OpenTelemetry attributes hash with non-nil values
    #
    # @example
    #   attrs = Langfuse::Types::TraceAttributes.new(
    #     name: "user-checkout-flow",
    #     user_id: "user-123",
    #     session_id: "session-456",
    #     tags: ["checkout", "payment"],
    #     metadata: { version: "2.1.0" }
    #   )
    #   otel_attrs = Langfuse::OtelAttributes.create_trace_attributes(attrs)
    #
    def self.create_trace_attributes(attrs)
      # Convert to hash if it's a TraceAttributes object
      attrs = attrs.to_h
      get_value = ->(key) { get_hash_value(attrs, key) }

      attributes = {
        TRACE_NAME => get_value.call(:name),
        TRACE_USER_ID => get_value.call(:user_id),
        TRACE_SESSION_ID => get_value.call(:session_id),
        VERSION => get_value.call(:version),
        RELEASE => get_value.call(:release),
        TRACE_INPUT => serialize(get_value.call(:input)),
        TRACE_OUTPUT => serialize(get_value.call(:output)),
        TRACE_TAGS => serialize(get_value.call(:tags)),
        ENVIRONMENT => get_value.call(:environment),
        TRACE_PUBLIC => get_value.call(:public),
        **flatten_metadata(get_value.call(:metadata), TRACE_METADATA)
      }

      # Remove nil values
      attributes.compact
    end

    # Creates OpenTelemetry attributes from Langfuse observation attributes
    #
    # Converts user-friendly observation attributes into the internal OpenTelemetry
    # attribute format required by the span processor.
    #
    # @param type [String] Observation type (e.g., "generation", "span", "event")
    # @param attrs [Types::SpanAttributes, Types::GenerationAttributes, Hash] Observation attributes
    # @return [Hash] OpenTelemetry attributes hash with non-nil values
    #
    # @example
    #   attrs = Langfuse::Types::GenerationAttributes.new(
    #     model: "gpt-4",
    #     input: { messages: [...] },
    #     usage_details: { prompt_tokens: 100 }
    #   )
    #   otel_attrs = Langfuse::OtelAttributes.create_observation_attributes("generation", attrs)
    #
    def self.create_observation_attributes(type, attrs)
      attrs = attrs.to_h
      get_value = ->(key) { get_hash_value(attrs, key) }

      otel_attributes = build_observation_base_attributes(type, get_value)
      add_prompt_attributes(otel_attributes, get_value.call(:prompt))

      # Remove nil values
      otel_attributes.compact
    end

    # Safely serializes an object to JSON string
    #
    # @param obj [Object, nil] Object to serialize
    # @param preserve_strings [Boolean] If true, preserves strings as-is; if false, JSON-serializes everything including strings
    # @return [String, nil] JSON string, original string (if preserve_strings is true), or nil if nil/undefined
    #
    # @example Always JSON-serialize (default)
    #   serialize({ key: "value" }) # => '{"key":"value"}'
    #   serialize("string") # => '"string"'
    #   serialize(nil) # => nil
    #
    # @example Preserve strings
    #   serialize("already a string", preserve_strings: true) # => "already a string"
    #   serialize([1, 2, 3], preserve_strings: true) # => "[1,2,3]"
    #
    # @api private
    def self.serialize(obj, preserve_strings: false)
      return nil if obj.nil?
      return obj if preserve_strings && obj.is_a?(String)

      begin
        obj.to_json
      rescue StandardError
        nil
      end
    end

    # Flattens and serializes metadata into OpenTelemetry attribute format
    #
    # Converts nested metadata objects into dot-notation attribute keys.
    # For example, `{ database: { host: 'localhost' } }` becomes
    # `{ 'langfuse.trace.metadata.database.host': 'localhost' }`.
    #
    # @param metadata [Hash, Array, Object, nil] Metadata to flatten
    # @param prefix [String] Prefix for attribute keys (e.g., "langfuse.trace.metadata")
    # @return [Hash] Flattened metadata attributes
    #
    # @example
    #   flatten_metadata({ user: { id: 123 } }, "langfuse.trace.metadata")
    #   # => { "langfuse.trace.metadata.user.id" => "123" }
    #
    def self.flatten_metadata(metadata, prefix)
      return {} if metadata.nil?

      # Handle non-hash metadata (arrays, primitives, etc.)
      unless metadata.is_a?(Hash)
        serialized = serialize(metadata, preserve_strings: true)
        return serialized ? { prefix => serialized } : {}
      end

      # Recursively flatten hash metadata
      result = {}
      metadata.each do |key, value|
        next if value.nil?

        new_key = "#{prefix}.#{key}"
        result.merge!(flatten_hash_value(value, new_key))
      end

      result
    end

    # Flattens a single hash value (recursively if it's a hash, serializes otherwise)
    #
    # @param value [Object] Value to flatten
    # @param key [String] Attribute key prefix
    # @return [Hash] Flattened attributes hash
    # @api private
    def self.flatten_hash_value(value, key)
      if value.is_a?(Hash)
        # Recursively flatten nested hashes
        flatten_metadata(value, key)
      elsif value.is_a?(Array)
        # Serialize arrays to JSON
        serialized = serialize(value, preserve_strings: true)
        serialized ? { key => serialized } : {}
      else
        # Convert simple values (strings, numbers, booleans) to strings
        { key => value.to_s }
      end
    end

    # Gets a value from a hash supporting both symbol and string keys
    # Handles false values correctly (doesn't treat false as nil)
    #
    # @param hash [Hash] Hash to get value from
    # @param key [Symbol, String] Key to look up
    # @return [Object, nil] Value from hash or nil
    # @api private
    def self.get_hash_value(hash, key)
      return hash[key] if hash.key?(key)
      return hash[key.to_s] if hash.key?(key.to_s)

      nil
    end

    # Builds base observation attributes (without prompt)
    #
    # @param type [String] Observation type
    # @param get_value [Proc] Lambda to get values from attributes hash
    # @return [Hash] Base observation attributes
    # @api private
    def self.build_observation_base_attributes(type, get_value)
      {
        OBSERVATION_TYPE => type,
        OBSERVATION_LEVEL => get_value.call(:level),
        OBSERVATION_STATUS_MESSAGE => get_value.call(:status_message),
        VERSION => get_value.call(:version),
        OBSERVATION_INPUT => serialize(get_value.call(:input)),
        OBSERVATION_OUTPUT => serialize(get_value.call(:output)),
        OBSERVATION_MODEL => get_value.call(:model),
        OBSERVATION_USAGE_DETAILS => serialize(get_value.call(:usage_details)),
        OBSERVATION_COST_DETAILS => serialize(get_value.call(:cost_details)),
        OBSERVATION_COMPLETION_START_TIME => serialize(get_value.call(:completion_start_time)),
        OBSERVATION_MODEL_PARAMETERS => serialize(get_value.call(:model_parameters)),
        ENVIRONMENT => get_value.call(:environment),
        **flatten_metadata(get_value.call(:metadata), OBSERVATION_METADATA)
      }
    end

    # Adds prompt attributes if prompt is present and not a fallback
    #
    # @param otel_attributes [Hash] Attributes hash to modify
    # @param prompt [Hash, Object, nil] Prompt hash or object
    # @return [void]
    # @api private
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def self.add_prompt_attributes(otel_attributes, prompt)
      return unless prompt

      # Handle hash-like prompts
      if prompt.is_a?(Hash) || prompt.respond_to?(:[])
        return if prompt[:is_fallback] || prompt["is_fallback"]

        otel_attributes[OBSERVATION_PROMPT_NAME] = prompt[:name] || prompt["name"]
        otel_attributes[OBSERVATION_PROMPT_VERSION] = prompt[:version] || prompt["version"]
      # Handle objects with name/version methods (already converted in Trace#generation)
      elsif prompt.respond_to?(:name) && prompt.respond_to?(:version)
        otel_attributes[OBSERVATION_PROMPT_NAME] = prompt.name
        otel_attributes[OBSERVATION_PROMPT_VERSION] = prompt.version
      end
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ModuleLength
end
