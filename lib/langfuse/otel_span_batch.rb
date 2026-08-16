# frozen_string_literal: true

require "opentelemetry/sdk"
require_relative "otel_span_masking"

module Langfuse
  # Builds immutable hook input while retaining original spans for export.
  # @api private
  class OtelSpanBatch
    attr_reader :spans

    def initialize(span_data:, logger:)
      @logger = logger
      @spans_by_identifier = index_spans(span_data)
      @spans = @spans_by_identifier.values.freeze
    end

    def empty?
      @spans_by_identifier.empty?
    end

    def include_identifier?(identifier)
      @spans_by_identifier.key?(identifier)
    end

    def masking_params
      MaskOtelSpansParams.new(spans: snapshots)
    end

    def apply(patches, patch_applier:)
      @spans_by_identifier.filter_map do |identifier, span|
        patch = patches[identifier]
        patch.nil? ? span : patch_applier.apply(span, patch)
      end
    end

    private

    def index_spans(span_data)
      span_data.each_with_object({}) do |span, indexed_spans|
        unless valid_span_context?(span)
          @logger.warn("Langfuse mask_otel_spans dropped a span with an invalid span context")
          next
        end

        identifier = span_identifier(span)
        indexed_spans.delete(identifier)
        indexed_spans[identifier] = span
      end
    end

    def valid_span_context?(span)
      span.trace_id.is_a?(String) && span.trace_id.bytesize == 16 &&
        span.span_id.is_a?(String) && span.span_id.bytesize == 8 &&
        span.trace_id != OpenTelemetry::Trace::INVALID_TRACE_ID &&
        span.span_id != OpenTelemetry::Trace::INVALID_SPAN_ID
    end

    def span_identifier(span)
      OtelSpanIdentifier.new(trace_id: span.hex_trace_id, span_id: span.hex_span_id)
    end

    def snapshots
      @snapshots ||= @spans_by_identifier.to_h do |identifier, span|
        [identifier, snapshot_span(identifier, span)]
      end.freeze
    end

    def snapshot_span(identifier, span)
      scope = span.instrumentation_scope
      OtelSpanData.new(
        trace_id: identifier.trace_id,
        span_id: identifier.span_id,
        parent_span_id: parent_span_id(span),
        name: frozen_copy(span.name),
        instrumentation_scope_name: frozen_copy(scope&.name),
        instrumentation_scope_version: frozen_copy(scope&.version),
        attributes: frozen_attributes(span.attributes),
        resource_attributes: frozen_attributes(span.resource&.attribute_enumerator&.to_h)
      )
    end

    def parent_span_id(span)
      return if span.parent_span_id.nil? || span.parent_span_id == OpenTelemetry::Trace::INVALID_SPAN_ID

      span.hex_parent_span_id.freeze
    end

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
  private_constant :OtelSpanBatch
end
