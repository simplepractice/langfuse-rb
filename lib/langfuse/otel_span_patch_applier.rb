# frozen_string_literal: true

require "opentelemetry/sdk"
require_relative "otel_span_masking"

module Langfuse
  # Validates and applies one sparse patch to a cloned OpenTelemetry span.
  # @api private
  class OtelSpanPatchApplier
    def initialize(logger:)
      @logger = logger
    end

    def apply(span, patch)
      unless valid_patch_containers?(patch)
        @logger.error(
          "Langfuse mask_otel_spans produced an invalid span patch; dropping the span from the Langfuse export"
        )
        return nil
      end

      clone_with_attributes(span, patched_attributes(span, patch))
    end

    private

    def valid_patch_containers?(patch)
      patch.is_a?(OtelSpanPatch) &&
        patch.delete_attributes.is_a?(Array) &&
        patch.set_attributes.is_a?(Hash)
    end

    def patched_attributes(span, patch)
      attributes = (span.attributes || {}).dup
      patch.delete_attributes.each do |key|
        next warn_invalid_key("delete") unless valid_attribute_key?(key)

        attributes.delete(key)
      end
      patch.set_attributes.each do |key, value|
        next warn_invalid_key("set") unless valid_attribute_key?(key)

        apply_replacement(attributes, key, value)
      end
      attributes.freeze
    end

    def warn_invalid_key(operation)
      @logger.warn("Langfuse mask_otel_spans ignored an invalid #{operation} attribute key")
    end

    def apply_replacement(attributes, key, value)
      if OpenTelemetry::SDK::Internal.valid_value?(value)
        attributes[key] = frozen_copy(value)
      else
        attributes.delete(key)
        @logger.warn(
          "Langfuse mask_otel_spans replacement for attribute '#{key}' is not a valid " \
          "OpenTelemetry attribute value (#{value.class}); omitting the attribute"
        )
      end
    end

    def valid_attribute_key?(key)
      OpenTelemetry::SDK::Internal.valid_key?(key) && !key.empty?
    end

    def frozen_copy(value)
      case value
      when String then value.dup.freeze
      when Array then value.map { |element| frozen_copy(element) }.freeze
      else value
      end
    end

    def clone_with_attributes(span, attributes)
      copy = span.dup
      copy.attributes = attributes
      copy.total_recorded_attributes = attributes.size + dropped_attribute_count(span)
      copy
    end

    def dropped_attribute_count(span)
      [span.total_recorded_attributes.to_i - (span.attributes || {}).size, 0].max
    end
  end
  private_constant :OtelSpanPatchApplier
end
