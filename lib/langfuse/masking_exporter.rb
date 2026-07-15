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
  ) do
    class << self
      # Build an immutable snapshot without freezing objects owned by the
      # original span data.
      # @api private
      def from_span(span)
        new(
          trace_id: span.hex_trace_id,
          span_id: span.hex_span_id,
          name: frozen_copy(span.name),
          scope_name: frozen_copy(span.instrumentation_scope&.name),
          attributes: frozen_attributes(span.attributes),
          resource_attributes: frozen_attributes(span.resource&.attribute_enumerator&.to_h)
        )
      end

      private

      def frozen_attributes(attributes)
        (attributes || {}).to_h do |key, value|
          [frozen_copy(key), frozen_copy(value)]
        end.freeze
      end

      def frozen_copy(value)
        case value
        when String then value.dup.freeze
        when Array then value.map { |element| frozen_copy(element) }.freeze
        else value
        end
      end
    end
  end

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
      snapshots = snapshot_batch(batch)
      return unless snapshots

      patches = @hook.call(spans: snapshots)
      return batch if patches.nil?

      unless patches.is_a?(Hash)
        @logger.error(
          "Langfuse mask_otel_spans returned #{patches.class} instead of nil or a Hash " \
          "of patches; dropping the Langfuse export batch"
        )
        return nil
      end

      unless patches.each_key.all? { |identifier| snapshots.key?(identifier) }
        @logger.error(
          "Langfuse mask_otel_spans returned a patch for an unknown span identifier; " \
          "dropping the Langfuse export batch"
        )
        return nil
      end

      apply_patches(batch, patches)
    rescue StandardError => e
      # Only the exception class is logged: hook exception messages can carry
      # the sensitive attribute values the hook exists to mask.
      @logger.error("Langfuse mask_otel_spans raised #{e.class}; dropping the Langfuse export batch")
      nil
    end

    def snapshot_batch(batch)
      batch.each_with_object({}) do |span, snapshots|
        identifier = span_identifier(span)
        if snapshots.key?(identifier)
          @logger.error(
            "Langfuse mask_otel_spans received duplicate span identifiers; " \
            "dropping the Langfuse export batch"
          )
          return nil
        end

        snapshots[identifier] = OtelSpanSnapshot.from_span(span)
      end.freeze
    end

    # Stable identifier the hook uses to key sparse patches.
    def span_identifier(span)
      "#{span.hex_trace_id}:#{span.hex_span_id}"
    end

    # Unpatched spans are passed through untouched; patched spans are cloned
    # so the originals stay pristine for any other exporter.
    def apply_patches(batch, patches)
      batch.filter_map do |span|
        identifier = span_identifier(span)
        next span unless patches.key?(identifier)

        apply_patch(span, patches.fetch(identifier))
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
        valid_delete_keys?(patch[:delete]) &&
        valid_set_keys?(patch[:set])
    end

    def valid_delete_keys?(keys)
      keys.nil? || (keys.is_a?(Array) && keys.all? { |key| valid_attribute_key?(key) })
    end

    def valid_set_keys?(attributes)
      attributes.nil? || (attributes.is_a?(Hash) && attributes.each_key.all? { |key| valid_attribute_key?(key) })
    end

    # Deletes run before sets so a replacement wins when a key appears in both.
    def patched_attributes(span, patch)
      attributes = (span.attributes || {}).dup
      Array(patch[:delete]).each { |key| attributes.delete(key) }
      (patch[:set] || {}).each do |key, value|
        apply_replacement(attributes, key, value)
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
      OpenTelemetry::SDK::Internal.valid_value?(value)
    end

    def valid_attribute_key?(key)
      OpenTelemetry::SDK::Internal.valid_key?(key)
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
end
