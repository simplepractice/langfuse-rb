# frozen_string_literal: true

module Langfuse
  # Owns metadata encoding and the shared wire representation used by context and baggage.
  # @api private
  module MetadataEncoding
    # Bounded stripes serialize updates to the same span without retaining ended spans.
    SPAN_LOCKS = Array.new(64) { Mutex.new }.freeze
    private_constant :SPAN_LOCKS

    # Whole JSON objects are decoded independently of the Ruby SDK identity.
    # @param metadata [Object, nil] Metadata after creation-time masking
    # @param prefix [String] Metadata attribute name
    # @return [Hash] OpenTelemetry attributes
    # @raise [StandardError] if legacy metadata cannot be traversed
    def self.attributes(metadata, prefix)
      return OtelAttributes.flatten_metadata(metadata, prefix) unless json?
      return {} if metadata.nil?

      serialized = OtelAttributes.serialize(metadata)
      serialized ? { prefix => serialized } : {}
    end

    # Store immutable wire values in context, so baggage needs no second encoding.
    # Legacy paths are flattened here; JSON values remain atomic per top-level key.
    # @param metadata [Hash] User-provided metadata
    # @return [Hash<String, String>, nil] Frozen encoded values, or nil when none survive validation
    # @raise [NoMethodError] if metadata is not a hash
    def self.propagation_values(metadata)
      values = metadata.each_with_object({}) do |(key, value), result|
        encoded = JSON.generate(value)
        snapshot = JSON.parse(encoded, freeze: true)
        result[key.to_s] = json? ? encoded.freeze : snapshot
      rescue JSON::JSONError, EncodingError
        warn_dropped_value("is not valid JSON")
      end
      values = legacy_propagation_values(values) unless json?
      values.select! { |_key, value| within_propagation_limit?(value) }
      values.empty? ? nil : values.freeze
    end

    # @param values [Hash<String, String>] Encoded metadata values
    # @return [Hash] Prefixed metadata attributes
    # @raise [NoMethodError] if values is not a hash
    def self.propagated_attributes(values)
      values.transform_keys { |key| "#{OtelAttributes::TRACE_METADATA}.#{key}" }
    end

    # Merge context and baggage per key before producing the single JSON object.
    # Legacy baggage strings that are not JSON keep their original value.
    # @param attributes [Hash] Merged baggage and context attributes
    # @return [Hash] Attributes in the configured wire format
    # @raise [JSON::GeneratorError] if baggage cannot be encoded as JSON
    def self.consolidate_propagated_attributes(attributes)
      return attributes unless json?

      prefix = "#{OtelAttributes::TRACE_METADATA}."
      result = attributes.dup
      metadata = {}
      attributes.each do |key, value|
        next unless key.start_with?(prefix)

        metadata[key.delete_prefix(prefix)] = decode_baggage_value(value)
        result.delete(key)
      end
      return attributes if metadata.empty?

      key = OtelAttributes::TRACE_METADATA
      result[key] = merge_metadata_objects(attributes[key], JSON.generate(metadata))
      result
    end

    # OpenTelemetry locks individual writes, not read/merge/write sequences.
    # Share this lock between observation updates and propagation to an active span.
    # @param span [OpenTelemetry::SDK::Trace::Span] Span receiving the attributes
    # @param attributes [Hash] Encoded attributes to set
    # @return [Hash] the supplied attributes
    # @raise [StandardError] if the span rejects an attribute
    def self.apply_to_span(span, attributes)
      return attributes.each { |key, value| span.set_attribute(key, value) } unless json?

      SPAN_LOCKS[span.object_id.hash % SPAN_LOCKS.length].synchronize do
        attributes.each do |key, value|
          if [OtelAttributes::TRACE_METADATA, OtelAttributes::OBSERVATION_METADATA].include?(key)
            value = merge_metadata_objects(span.attributes&.[](key), value)
          end
          span.set_attribute(key, value)
        end
      end
    end

    def self.json?
      Langfuse.configuration.metadata_encoding == :json
    end
    private_class_method :json?

    def self.within_propagation_limit?(wire_value)
      return true if wire_value.length <= 200

      warn_dropped_value("exceeds 200 characters")
      false
    end
    private_class_method :within_propagation_limit?

    def self.legacy_propagation_values(metadata)
      prefix = OtelAttributes::TRACE_METADATA
      OtelAttributes.flatten_metadata(metadata, prefix).to_h do |key, value|
        [key.delete_prefix("#{prefix}."), value.freeze]
      end
    end
    private_class_method :legacy_propagation_values

    def self.decode_baggage_value(value)
      JSON.parse(value)
    rescue JSON::ParserError
      value
    end
    private_class_method :decode_baggage_value

    def self.merge_metadata_objects(existing, replacement)
      return replacement unless existing

      previous = JSON.parse(existing)
      updated = JSON.parse(replacement)
      previous.is_a?(Hash) && updated.is_a?(Hash) ? JSON.generate(previous.merge(updated)) : replacement
    rescue JSON::ParserError, TypeError
      replacement
    end
    private_class_method :merge_metadata_objects

    def self.warn_dropped_value(reason)
      Langfuse.configuration.logger.warn("Langfuse: Propagated metadata value #{reason}. Dropping value.")
    end
    private_class_method :warn_dropped_value
  end
end
