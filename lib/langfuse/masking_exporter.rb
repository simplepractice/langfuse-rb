# frozen_string_literal: true

require "opentelemetry/sdk"

module Langfuse
  # Immutable snapshot of one span in a Langfuse export batch.
  #
  # Passed to the {Config#mask_otel_spans} hook as the values of the +spans:+
  # mapping. Exposes only the fields needed to make a masking decision; the
  # mutable OpenTelemetry SDK span objects are never handed to the hook.
  #
  # @!attribute [r] trace_id
  #   @return [String] 32-hex-character lowercase trace ID
  # @!attribute [r] span_id
  #   @return [String] 16-hex-character lowercase span ID
  # @!attribute [r] name
  #   @return [String] span name
  # @!attribute [r] scope_name
  #   @return [String, nil] instrumentation scope name (e.g. "ruby-openai")
  # @!attribute [r] attributes
  #   @return [Hash] frozen span attributes
  # @!attribute [r] resource_attributes
  #   @return [Hash] frozen resource attributes
  OtelSpanSnapshot = Data.define(
    :trace_id, :span_id, :name, :scope_name, :attributes, :resource_attributes
  )

  # Export-stage masking wrapper around the Langfuse OTLP exporter.
  #
  # Applies the {Config#mask_otel_spans} hook to every export batch after
  # +should_export_span+ has selected spans and the batch processor has built
  # the batch. Only the copy exported to Langfuse is transformed; original
  # span data (and therefore any other OpenTelemetry exporter) is untouched.
  #
  # Fail-closed behavior:
  # - A hook exception or an invalid top-level result drops the whole batch.
  # - A malformed per-span patch drops that span from the Langfuse export.
  # - An invalid replacement attribute value omits that attribute entirely
  #   rather than exporting its original value.
  #
  # @api private
  class MaskingExporter
    SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
    FAILURE = OpenTelemetry::SDK::Trace::Export::FAILURE
    private_constant :SUCCESS, :FAILURE

    # Allowed keys of one sparse span patch.
    PATCH_KEYS = %i[delete set].freeze
    private_constant :PATCH_KEYS

    # @param delegate [#export, #force_flush, #shutdown] Langfuse OTLP exporter
    # @param hook [#call] The configured mask_otel_spans callable
    # @param logger [Logger]
    def initialize(delegate:, hook:, logger:)
      @delegate = delegate
      @hook = hook
      @logger = logger
    end

    # Mask the batch and delegate export. Drops the whole batch (fail closed)
    # when the hook raises or returns an invalid result.
    #
    # @param span_data [Enumerable<OpenTelemetry::SDK::Trace::SpanData>]
    # @param timeout [Numeric, nil]
    # @return [Integer] OpenTelemetry export result code
    def export(span_data, timeout: nil)
      batch = span_data.to_a
      masked = mask_batch(batch)
      return FAILURE unless masked

      @delegate.export(masked, timeout: timeout)
    end

    # @return [Object] delegate's force_flush result
    def force_flush(timeout: nil)
      @delegate.force_flush(timeout: timeout)
    end

    # @return [Object] delegate's shutdown result
    def shutdown(timeout: nil)
      @delegate.shutdown(timeout: timeout)
    end

    private

    # @return [Array<SpanData>, nil] the masked batch, or nil to drop it
    def mask_batch(batch)
      patches = @hook.call(spans: snapshot_batch(batch))
      return batch if patches.nil?

      unless patches.is_a?(Hash)
        @logger.error(
          "Langfuse mask_otel_spans returned #{patches.class} instead of nil or a Hash " \
          "of patches; dropping the Langfuse export batch"
        )
        return nil
      end

      apply_patches(batch, patches)
    rescue StandardError => e
      @logger.error("Langfuse mask_otel_spans raised #{e.class}: #{e.message}; dropping the Langfuse export batch")
      nil
    end

    def snapshot_batch(batch)
      batch.to_h { |span| [span_identifier(span), snapshot(span)] }.freeze
    end

    # Stable identifier the hook uses to key sparse patches.
    def span_identifier(span)
      "#{span.hex_trace_id}:#{span.hex_span_id}"
    end

    def snapshot(span)
      OtelSpanSnapshot.new(
        trace_id: span.hex_trace_id,
        span_id: span.hex_span_id,
        name: span.name,
        scope_name: span.instrumentation_scope&.name,
        attributes: frozen_attributes(span.attributes),
        resource_attributes: frozen_attributes(span.resource&.attribute_enumerator&.to_h)
      )
    end

    # Copies mutable values so freezing the snapshot never freezes objects
    # still referenced by the original span data.
    def frozen_attributes(attributes)
      (attributes || {}).transform_values { |value| frozen_copy(value) }.freeze
    end

    def frozen_copy(value)
      case value
      when String, Array then value.dup.freeze
      else value
      end
    end

    # Unpatched spans are passed through untouched; patched spans are cloned
    # so the originals stay pristine for any other exporter.
    def apply_patches(batch, patches)
      batch.filter_map do |span|
        patch = patches[span_identifier(span)]
        next span unless patch

        apply_patch(span, patch)
      end
    end

    # @return [SpanData, nil] the cloned masked span, or nil to drop it
    def apply_patch(span, patch)
      unless valid_patch?(patch)
        @logger.error(
          "Langfuse mask_otel_spans produced a malformed patch for span '#{span.name}'; " \
          "dropping the span from the Langfuse export"
        )
        return nil
      end

      clone_with_attributes(span, patched_attributes(span, patch))
    end

    def valid_patch?(patch)
      patch.is_a?(Hash) &&
        (patch.keys - PATCH_KEYS).empty? &&
        (patch[:delete].nil? || patch[:delete].is_a?(Array)) &&
        (patch[:set].nil? || patch[:set].is_a?(Hash))
    end

    # Deletes run before sets so a replacement wins when a key appears in both.
    def patched_attributes(span, patch)
      attributes = (span.attributes || {}).dup
      Array(patch[:delete]).each { |key| attributes.delete(key.to_s) }
      (patch[:set] || {}).each do |key, value|
        apply_replacement(attributes, key.to_s, value)
      end
      attributes.freeze
    end

    # Invalid replacements delete the key: never export the original value of
    # an attribute the hook intended to overwrite. The value itself is never
    # logged.
    def apply_replacement(attributes, key, value)
      if valid_attribute_value?(value)
        attributes[key] = value
      else
        attributes.delete(key)
        @logger.warn(
          "Langfuse mask_otel_spans replacement for attribute '#{key}' is not a valid " \
          "OpenTelemetry attribute value (#{value.class}); omitting the attribute"
        )
      end
    end

    def valid_attribute_value?(value)
      case value
      when String, Integer, Float, true, false then true
      when Array then homogeneous_scalar_array?(value)
      else false
      end
    end

    def homogeneous_scalar_array?(array)
      return true if array.empty?
      # Booleans mix TrueClass and FalseClass but form one OpenTelemetry type.
      return array.all? { |element| [true, false].include?(element) } if [true, false].include?(array.first)

      type = array.first.class
      [String, Integer, Float].include?(type) && array.all? { |element| element.instance_of?(type) }
    end

    def clone_with_attributes(span, attributes)
      copy = span.dup
      copy.attributes = attributes
      copy
    end
  end
end
