# frozen_string_literal: true

require "opentelemetry/context"
require "json"

module Langfuse
  # Attribute propagation utilities for Langfuse OpenTelemetry integration.
  #
  # This module provides the `propagate_attributes` method for setting trace-level
  # attributes (user_id, session_id, metadata) that automatically propagate to all child spans
  # within the context.
  #
  # @example Basic usage
  #   Langfuse.observe("operation") do |span|
  #     Langfuse.propagate_attributes(user_id: "user_123", session_id: "session_abc") do
  #       # Current span has user_id and session_id
  #       span.start_observation("child") do |child|
  #         # Child span inherits user_id and session_id
  #       end
  #     end
  #   end
  #
  # rubocop:disable Metrics/ModuleLength
  module Propagation
    # Map of propagated attribute keys to span attribute keys
    SPAN_KEY_MAP = {
      "user_id" => OtelAttributes::TRACE_USER_ID,
      "session_id" => OtelAttributes::TRACE_SESSION_ID,
      "version" => OtelAttributes::VERSION,
      "tags" => OtelAttributes::TRACE_TAGS,
      "metadata" => OtelAttributes::TRACE_METADATA
    }.freeze

    # OpenTelemetry context keys for propagated attributes
    CONTEXT_KEYS = {
      "user_id" => OpenTelemetry::Context.create_key("langfuse_user_id"),
      "session_id" => OpenTelemetry::Context.create_key("langfuse_session_id"),
      "metadata" => OpenTelemetry::Context.create_key("langfuse_metadata"),
      "version" => OpenTelemetry::Context.create_key("langfuse_version"),
      "tags" => OpenTelemetry::Context.create_key("langfuse_tags")
    }.freeze

    # List of propagated attribute keys (derived from CONTEXT_KEYS)
    PROPAGATED_ATTRIBUTES = CONTEXT_KEYS.keys.freeze

    # Baggage key prefix for cross-service propagation
    BAGGAGE_PREFIX = "langfuse_"

    # Propagate trace-level attributes to all spans created within this context.
    #
    # This method sets attributes on the currently active span AND automatically
    # propagates them to all new child spans created within the block. This is the
    # recommended way to set trace-level attributes like user_id, session_id, and metadata
    # dimensions that should be consistently applied across all observations in a trace.
    #
    # @param user_id [String, nil] User identifier (≤200 characters)
    # @param session_id [String, nil] Session identifier (≤200 characters)
    # @param metadata [Hash, nil] Structured trace metadata. When `config.mask` is set,
    #   the masked value is stored on the active span, in OpenTelemetry context, and
    #   optionally in baggage so child spans do not reintroduce raw metadata.
    # @param version [String, nil] Version identifier (≤200 characters)
    # @param tags [Array<String>, nil] List of tags (each ≤200 characters)
    # @param as_baggage [Boolean] If true, propagates via OpenTelemetry baggage for cross-service propagation
    # @yield Block within which attributes are propagated
    # @return [Object] The result of the block
    # @raise [ArgumentError] if no block is given
    #
    # @example Basic usage
    #   Langfuse.propagate_attributes(user_id: "user_123", session_id: "session_abc") do
    #     # All spans created here inherit attributes
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
    def self.propagate_attributes(user_id: nil, session_id: nil, metadata: nil, version: nil, tags: nil,
                                  as_baggage: false, &block)
      raise ArgumentError, "Block required" unless block

      _propagate_attributes(
        user_id: user_id,
        session_id: session_id,
        metadata: metadata,
        version: version,
        tags: tags,
        as_baggage: as_baggage,
        &block
      )
    end

    # Internal implementation of propagate_attributes
    #
    # @api private
    def self._propagate_attributes(user_id: nil, session_id: nil, metadata: nil, version: nil, tags: nil,
                                   as_baggage: false, &)
      current_context = OpenTelemetry::Context.current
      current_span = OpenTelemetry::Trace.current_span

      # Process each propagated attribute using PROPAGATED_ATTRIBUTES constant
      PROPAGATED_ATTRIBUTES.each do |key|
        value = binding.local_variable_get(key.to_sym)
        next if value.nil?
        next if key == "tags" && value.empty?

        validated_value = _validate_attribute_value(key, value)
        next unless validated_value

        current_context = _set_propagated_attribute(
          key: key,
          value: validated_value,
          context: current_context,
          span: current_span,
          as_baggage: as_baggage
        )
      end

      # Execute block in new context
      OpenTelemetry::Context.with_current(current_context, &)
    end

    # Validate an attribute value based on its type
    #
    # @param key [String] Attribute key
    # @param value [Object] Attribute value
    # @return [Object, nil] Validated value or nil if invalid
    #
    # @api private
    def self._validate_attribute_value(key, value)
      case key
      when "tags"
        validated_tags = value.filter_map { |tag| _validate_propagated_value(tag, "tag") }
        validated_tags.any? ? validated_tags : nil
      when "metadata"
        _validate_metadata_value(value)
      else
        _validate_propagated_value(value, key)
      end
    end

    # Get propagated attributes from context for span processor
    #
    # @param context [OpenTelemetry::Context] The context to read from
    # @return [Hash<String, String, Array<String>>] Hash of span key => value
    #
    # @api private
    def self.get_propagated_attributes_from_context(context)
      propagated_attributes = _extract_baggage_attributes(context)

      # Handle OTEL context values
      PROPAGATED_ATTRIBUTES.each do |key|
        context_key = _get_propagated_context_key(key)
        value = context.value(context_key)

        next if value.nil?

        span_key = _get_propagated_span_key(key)

        if key == "metadata"
          propagated_attributes.merge!(_flatten_metadata_attributes(value))
        elsif key == "tags" && value.is_a?(Array)
          propagated_attributes[span_key] = value unless value.empty?
        else
          propagated_attributes[span_key] = value.to_s
        end
      end

      propagated_attributes
    end

    # Merge metadata with existing context value
    #
    # @param context [OpenTelemetry::Context] Current context
    # @param context_key [OpenTelemetry::Context::Key] Context key for metadata
    # @param new_metadata [Hash<String, String>] New metadata to merge
    # @return [Hash, String] Merged metadata
    #
    # @api private
    def self._merge_metadata(context, context_key, new_metadata)
      existing = context.value(context_key) || {}
      existing = existing.to_h if existing.respond_to?(:to_h)
      return new_metadata unless existing.is_a?(Hash) && new_metadata.is_a?(Hash)

      existing.merge(new_metadata)
    end

    # Merge tags with existing context value
    #
    # @param context [OpenTelemetry::Context] Current context
    # @param context_key [OpenTelemetry::Context::Key] Context key for tags
    # @param new_tags [Array<String>] New tags to merge
    # @return [Array<String>] Merged tags (deduplicated)
    #
    # @api private
    def self._merge_tags(context, context_key, new_tags)
      existing = context.value(context_key) || []
      existing = existing.to_a if existing.respond_to?(:to_a)
      (existing + new_tags).uniq.freeze
    end

    # Set a propagated attribute in context and on current span
    #
    # @param key [String] Attribute key (user_id, session_id, version, tags, metadata)
    # @param value [String, Array<String>, Hash<String, String>] Attribute value
    # @param context [OpenTelemetry::Context] Current context
    # @param span [OpenTelemetry::Trace::Span, nil] Current span (may be nil)
    # @param as_baggage [Boolean] Whether to set in baggage
    # @return [OpenTelemetry::Context] New context with attribute set
    #
    # @api private
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    def self._set_propagated_attribute(key:, value:, context:, span:, as_baggage:)
      context_key = _get_propagated_context_key(key)
      span_key = _get_propagated_span_key(key)
      baggage_key = _get_propagated_baggage_key(key)

      # Merge metadata/tags with existing context values
      value = if key == "metadata" && value.is_a?(Hash)
                _merge_metadata(context, context_key, value)
              elsif key == "tags" && value.is_a?(Array)
                _merge_tags(context, context_key, value)
              else
                value
              end

      # Set in context
      context = context.set_value(context_key, value)

      # Set on current span (if recording)
      if span&.recording?
        if key == "metadata"
          _flatten_metadata_attributes(value).each do |attribute_key, attribute_value|
            span.set_attribute(attribute_key, attribute_value)
          end
        elsif key == "tags" && value.is_a?(Array)
          span.set_attribute(span_key, value) unless value.empty?
        else
          span.set_attribute(span_key, value.to_s)
        end
      end

      # Set in baggage (if requested and available)
      # Note: Baggage support requires opentelemetry-baggage gem
      if as_baggage
        unless baggage_available?
          Langfuse.configuration.logger.warn(
            "Langfuse: Baggage propagation requested but opentelemetry-baggage gem not available. " \
            "Install opentelemetry-baggage for cross-service propagation."
          )
        end

        context = _set_baggage_attribute(
          context: context,
          key: key,
          value: value,
          baggage_key: baggage_key
        )
      end

      context
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

    # Validate a propagated value (string or array of strings)
    #
    # @param value [String, Array<String>] Value to validate
    # @param key [String] Attribute key for error messages
    # @return [String, Array<String>, nil] Validated value or nil if invalid
    #
    # @api private
    def self._validate_propagated_value(value, key)
      if value.is_a?(Array)
        validated = value.filter_map { |v| _validate_string_value(v, key) ? v : nil }
        return validated.any? ? validated : nil
      end

      # Validate string value (will log warning if not a string)
      return nil unless _validate_string_value(value, key)

      value
    end

    # Validate a string value
    #
    # @param value [String] Value to validate
    # @param key [String] Attribute key for error messages
    # @return [Boolean] True if valid, false otherwise
    #
    # @api private
    # rubocop:disable Naming/PredicateMethod
    def self._validate_string_value(value, key)
      unless value.is_a?(String)
        Langfuse.configuration.logger.warn(
          "Langfuse: Propagated attribute '#{key}' value is not a string. Dropping value."
        )
        return false
      end

      if value.length > 200
        Langfuse.configuration.logger.warn(
          "Langfuse: Propagated attribute '#{key}' value is over 200 characters " \
          "(#{value.length} chars). Dropping value."
        )
        return false
      end

      true
    end
    # rubocop:enable Naming/PredicateMethod

    # Get context key for a propagated attribute
    #
    # @param key [String] Attribute key (user_id, session_id, etc.)
    # @return [OpenTelemetry::Context::Key] Context key object
    # @raise [ArgumentError] if key is not a known propagated attribute
    #
    # @api private
    def self._get_propagated_context_key(key)
      CONTEXT_KEYS[key] || raise(ArgumentError, "Unknown propagated attribute key: #{key}")
    end

    # Get span attribute key for a propagated attribute
    #
    # @param key [String] Attribute key (user_id, session_id, etc.)
    # @return [String] Span attribute key
    #
    # @api private
    def self._get_propagated_span_key(key)
      SPAN_KEY_MAP[key] || "#{OtelAttributes::TRACE_METADATA}.#{key}"
    end

    # Get baggage key for a propagated attribute
    #
    # @param key [String] Attribute key (user_id, session_id, etc.)
    # @return [String] Baggage key (snake_case for cross-service compatibility)
    #
    # @api private
    def self._get_propagated_baggage_key(key)
      "#{BAGGAGE_PREFIX}#{key}"
    end

    # Get span key from baggage key
    #
    # @param baggage_key [String] Baggage key
    # @return [String, nil] Span key or nil if not a Langfuse baggage key
    #
    # @api private
    def self._get_span_key_from_baggage_key(baggage_key)
      return nil unless baggage_key.start_with?(BAGGAGE_PREFIX)

      suffix = baggage_key[BAGGAGE_PREFIX.length..]

      return OtelAttributes::TRACE_METADATA if suffix == "metadata"

      # Handle metadata keys (format: langfuse_metadata_{key_name})
      if suffix.start_with?("metadata_")
        metadata_key = suffix[("metadata_".length)..]
        return "#{OtelAttributes::TRACE_METADATA}.#{metadata_key}"
      end

      SPAN_KEY_MAP[suffix]
    end

    # Check if baggage API is available
    #
    # @return [Boolean] True if OpenTelemetry::Baggage is defined
    #
    # @api private
    def self.baggage_available?
      defined?(OpenTelemetry::Baggage)
    end

    # Parse a baggage value into the appropriate format
    #
    # @param span_key [String] The span attribute key
    # @param baggage_value [String, Object] The baggage value
    # @return [String, Array<String>] Parsed value
    #
    # @api private
    def self._parse_baggage_value(span_key, baggage_value)
      if span_key == OtelAttributes::TRACE_TAGS && baggage_value.is_a?(String)
        baggage_value.split(",")
      elsif span_key == OtelAttributes::TRACE_METADATA
        _deserialize_metadata_value(baggage_value)
      else
        baggage_value.to_s
      end
    end

    # Set a propagated attribute in baggage
    #
    # @param context [OpenTelemetry::Context] Current context
    # @param key [String] Attribute key (user_id, session_id, version, tags, metadata)
    # @param value [String, Array<String>, Hash<String, String>] Attribute value
    # @param baggage_key [String] Baggage key prefix
    # @return [OpenTelemetry::Context] New context with baggage set
    #
    # @api private
    def self._set_baggage_attribute(context:, key:, value:, baggage_key:)
      return context unless baggage_available?

      if key == "metadata"
        serialized = OtelAttributes.serialize(value, preserve_strings: true)
        return context unless serialized

        context = OpenTelemetry::Baggage.set_value(baggage_key, serialized, context: context)
      elsif key == "tags" && value.is_a?(Array)
        context = OpenTelemetry::Baggage.set_value(baggage_key, value.join(","), context: context)
      else
        context = OpenTelemetry::Baggage.set_value(baggage_key, value.to_s, context: context)
      end
      context
    rescue StandardError => e
      Langfuse.configuration.logger.warn("Langfuse: Failed to set baggage: #{e.message}")
      context
    end

    # Masks before type-checking so the mask function receives the raw value.
    # @api private
    def self._validate_metadata_value(value)
      masked_value = PayloadMasker.mask(value)
      return nil if masked_value.nil?
      return masked_value if masked_value == PayloadMasker::MASK_FAILURE_PLACEHOLDER

      unless masked_value.is_a?(Hash)
        Langfuse.configuration.logger.warn(
          "Langfuse: Propagated attribute 'metadata' value must be a Hash. Dropping value."
        )
        return nil
      end

      _normalize_metadata_value(masked_value)
    end

    # Recursive normalizer with identity-based cycle detection to safely handle
    # self-referencing structures (hashes/arrays that contain themselves).
    # @api private
    def self._normalize_metadata_value(value, active = {}.compare_by_identity)
      case value
      when Hash
        _normalize_metadata_hash(value, active)
      when Array
        _normalize_metadata_array(value, active)
      else
        value
      end
    end

    # @api private
    def self._normalize_metadata_hash(value, active)
      return {} if active.key?(value)

      active = active.dup.compare_by_identity
      active[value] = true
      value.each_with_object({}) do |(key, nested_value), normalized|
        normalized_value = _normalize_metadata_value(nested_value, active)
        normalized[key.to_s] = normalized_value unless normalized_value.nil?
      end
    end

    # @api private
    def self._normalize_metadata_array(value, active)
      return [] if active.key?(value)

      active = active.dup.compare_by_identity
      active[value] = true
      value.map { |nested_value| _normalize_metadata_value(nested_value, active) }
    end

    def self._extract_baggage_attributes(context)
      return {} unless baggage_available?

      baggage = OpenTelemetry::Baggage.values(context: context)
      return {} unless baggage.is_a?(Hash)

      metadata, attributes = _extract_langfuse_baggage_values(baggage)
      attributes.merge!(_flatten_metadata_attributes(metadata))
    rescue StandardError => e
      Langfuse.configuration.logger.debug("Langfuse: Baggage extraction failed: #{e.message}")
      {}
    end

    # Metadata is separated from other baggage values because it requires
    # flattening into dot-notation OTel attributes, while other values map 1:1.
    # @api private
    def self._extract_langfuse_baggage_values(baggage)
      metadata = nil
      attributes = {}

      baggage.each do |baggage_key, baggage_value|
        span_key = _langfuse_span_key_for_baggage(baggage_key)
        next unless span_key

        if span_key == OtelAttributes::TRACE_METADATA
          metadata = _parse_baggage_value(span_key, baggage_value)
          next
        end

        attributes[span_key] = _parse_baggage_value(span_key, baggage_value)
      end

      [metadata, attributes]
    end

    def self._langfuse_span_key_for_baggage(baggage_key)
      return nil unless baggage_key.to_s.start_with?(BAGGAGE_PREFIX)

      _get_span_key_from_baggage_key(baggage_key.to_s)
    end

    def self._flatten_metadata_attributes(value)
      OtelAttributes.flatten_metadata(value, OtelAttributes::TRACE_METADATA)
    end

    def self._deserialize_metadata_value(value)
      JSON.parse(value.to_s)
    rescue JSON::ParserError
      value.to_s
    end

    private_class_method :_validate_metadata_value, :_normalize_metadata_value, :_normalize_metadata_hash,
                         :_normalize_metadata_array, :_extract_langfuse_baggage_values,
                         :_langfuse_span_key_for_baggage, :_flatten_metadata_attributes,
                         :_deserialize_metadata_value
  end
end
# rubocop:enable Metrics/ModuleLength
