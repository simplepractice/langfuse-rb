# frozen_string_literal: true

require "opentelemetry/context"

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
    # @param metadata [Hash<String, String>, nil] Additional metadata (all values ≤200 characters)
    # @param version [String, nil] Version identifier (≤200 characters)
    # @param tags [Array<String>, nil] List of tags (each ≤200 characters)
    # @param as_baggage [Boolean] If true, propagates via OpenTelemetry baggage for cross-service propagation
    # @yield Block within which attributes are propagated
    # @return [Object] The result of the block
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
    # rubocop:disable Metrics/CyclomaticComplexity
    def self._validate_attribute_value(key, value)
      case key
      when "tags"
        validated_tags = value.filter_map { |tag| _validate_propagated_value(tag, "tag") }
        validated_tags.any? ? validated_tags : nil
      when "metadata"
        validated_metadata = {}
        value.each do |k, v|
          validated_metadata[k.to_s] = v.to_s if _validate_string_value(v, "metadata.#{k}")
        end
        validated_metadata.any? ? validated_metadata : nil
      else
        _validate_propagated_value(value, key)
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity

    # Get propagated attributes from context for span processor
    #
    # @param context [OpenTelemetry::Context] The context to read from
    # @return [Hash<String, String, Array<String>>] Hash of span key => value
    #
    # @api private
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def self.get_propagated_attributes_from_context(context)
      propagated_attributes = _extract_baggage_attributes(context)

      # Handle OTEL context values
      PROPAGATED_ATTRIBUTES.each do |key|
        context_key = _get_propagated_context_key(key)
        value = context.value(context_key)

        next if value.nil?

        span_key = _get_propagated_span_key(key)

        if key == "metadata" && value.is_a?(Hash)
          # Handle metadata - flatten into individual attributes
          value.each do |k, v|
            metadata_key = "#{OtelAttributes::TRACE_METADATA}.#{k}"
            propagated_attributes[metadata_key] = v.to_s
          end
        elsif key == "tags" && value.is_a?(Array)
          # Handle tags - serialize as JSON array for span attributes
          serialized_tags = OtelAttributes.serialize(value)
          propagated_attributes[span_key] = serialized_tags if serialized_tags
        else
          propagated_attributes[span_key] = value.to_s
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      propagated_attributes
    end

    # Merge metadata with existing context value
    #
    # @param context [OpenTelemetry::Context] Current context
    # @param context_key [OpenTelemetry::Context::Key] Context key for metadata
    # @param new_metadata [Hash<String, String>] New metadata to merge
    # @return [Hash<String, String>] Merged metadata
    #
    # @api private
    def self._merge_metadata(context, context_key, new_metadata)
      existing = context.value(context_key) || {}
      existing = existing.to_h if existing.respond_to?(:to_h)
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
      (existing + new_tags).uniq
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
        if key == "metadata" && value.is_a?(Hash)
          # Handle metadata - flatten into individual attributes
          value.each do |k, v|
            metadata_key = "#{OtelAttributes::TRACE_METADATA}.#{k}"
            span.set_attribute(metadata_key, v.to_s)
          end
        elsif key == "tags" && value.is_a?(Array)
          # Handle tags - serialize as JSON array
          serialized_tags = OtelAttributes.serialize(value)
          span.set_attribute(span_key, serialized_tags) if serialized_tags
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

      # Remove prefix
      suffix = baggage_key[BAGGAGE_PREFIX.length..]

      # Handle metadata keys (format: langfuse_metadata_{key_name})
      if suffix.start_with?("metadata_")
        metadata_key = suffix[("metadata_".length)..]
        return "#{OtelAttributes::TRACE_METADATA}.#{metadata_key}"
      end

      # Map standard keys
      case suffix
      when "user_id"
        _get_propagated_span_key("user_id")
      when "session_id"
        _get_propagated_span_key("session_id")
      when "version"
        _get_propagated_span_key("version")
      when "tags"
        _get_propagated_span_key("tags")
      end
    end

    # Check if baggage API is available
    #
    # @return [Boolean] True if OpenTelemetry::Baggage is defined
    #
    # @api private
    def self.baggage_available?
      defined?(OpenTelemetry::Baggage)
    end

    # Extract propagated attributes from baggage
    #
    # @param context [OpenTelemetry::Context] The context to read baggage from
    # @return [Hash<String, String, Array<String>>] Hash of span key => value
    #
    # @api private
    def self._extract_baggage_attributes(context)
      return {} unless baggage_available?

      baggage = OpenTelemetry::Baggage.value(context: context)
      return {} unless baggage.is_a?(Hash)

      attributes = {}
      baggage.each do |baggage_key, baggage_value|
        next unless baggage_key.to_s.start_with?(BAGGAGE_PREFIX)

        span_key = _get_span_key_from_baggage_key(baggage_key.to_s)
        next unless span_key

        attributes[span_key] = _parse_baggage_value(span_key, baggage_value)
      end
      attributes
    rescue StandardError => e
      Langfuse.configuration.logger.debug("Langfuse: Baggage extraction failed: #{e.message}")
      {}
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
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def self._set_baggage_attribute(context:, key:, value:, baggage_key:)
      return context unless baggage_available?

      if key == "metadata" && value.is_a?(Hash)
        value.each do |k, v|
          entry_key = "#{baggage_key}_#{k}"
          context = OpenTelemetry::Baggage.set_value(context: context, key: entry_key, value: v.to_s)
        end
      elsif key == "tags" && value.is_a?(Array)
        context = OpenTelemetry::Baggage.set_value(context: context, key: baggage_key, value: value.join(","))
      else
        context = OpenTelemetry::Baggage.set_value(context: context, key: baggage_key, value: value.to_s)
      end
      context
    rescue StandardError => e
      Langfuse.configuration.logger.warn("Langfuse: Failed to set baggage: #{e.message}")
      context
    end
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  end
end
# rubocop:enable Metrics/ModuleLength
