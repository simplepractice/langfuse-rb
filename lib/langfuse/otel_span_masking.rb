# frozen_string_literal: true

module Langfuse
  # Stable key for one OpenTelemetry span in a masking batch.
  #
  # Reuse identifiers from {MaskOtelSpansParams#spans} when returning patches.
  #
  # @!attribute [r] trace_id
  #   @return [String] 32-character lowercase hexadecimal trace ID
  # @!attribute [r] span_id
  #   @return [String] 16-character lowercase hexadecimal span ID
  OtelSpanIdentifier = Data.define(:trace_id, :span_id) do
    # @param trace_id [String] 32-character lowercase hexadecimal trace ID
    # @param span_id [String] 16-character lowercase hexadecimal span ID
    # @return [OtelSpanIdentifier]
    # @raise [TypeError] if an identifier cannot be copied
    def initialize(trace_id:, span_id:)
      super(trace_id: trace_id.dup.freeze, span_id: span_id.dup.freeze)
    end
  end

  # Read-only OpenTelemetry span snapshot passed to +mask_otel_spans+.
  #
  # The hook can inspect every field but can only patch +attributes+.
  #
  # @!attribute [r] trace_id
  #   @return [String] 32-character lowercase hexadecimal trace ID
  # @!attribute [r] span_id
  #   @return [String] 16-character lowercase hexadecimal span ID
  # @!attribute [r] parent_span_id
  #   @return [String, nil] 16-character lowercase hexadecimal parent span ID
  # @!attribute [r] name
  #   @return [String] span name
  # @!attribute [r] instrumentation_scope_name
  #   @return [String, nil] instrumentation scope name
  # @!attribute [r] instrumentation_scope_version
  #   @return [String, nil] instrumentation scope version
  # @!attribute [r] attributes
  #   @return [Hash] frozen span attributes
  # @!attribute [r] resource_attributes
  #   @return [Hash] frozen resource attributes
  OtelSpanData = Data.define(
    :trace_id,
    :span_id,
    :parent_span_id,
    :name,
    :instrumentation_scope_name,
    :instrumentation_scope_version,
    :attributes,
    :resource_attributes
  )

  # Input passed to the export-stage masking hook.
  #
  # @!attribute [r] spans
  #   @return [Hash{OtelSpanIdentifier => OtelSpanData}] frozen batch snapshot
  MaskOtelSpansParams = Data.define(:spans)

  # Attribute changes for one exported OpenTelemetry span.
  #
  # Deletes run before sets, so a set wins when the same key is in both fields.
  #
  # @!attribute [r] set_attributes
  #   @return [Hash] attributes to add or replace
  # @!attribute [r] delete_attributes
  #   @return [Array<String>] attribute keys to remove
  OtelSpanPatch = Data.define(:set_attributes, :delete_attributes) do
    # @param set_attributes [Object] attributes to add or replace
    # @param delete_attributes [Object] attribute keys to remove
    # @return [OtelSpanPatch]
    # @raise [ArgumentError] if an unknown keyword is given
    def initialize(set_attributes: {}, delete_attributes: [])
      super
    end
  end

  # Sparse patches returned by an export-stage masking hook.
  #
  # @!attribute [r] span_patches
  #   @return [Hash{OtelSpanIdentifier => OtelSpanPatch, nil}]
  MaskOtelSpansResult = Data.define(:span_patches) do
    # @param span_patches [Object] sparse patches keyed by batch identifiers
    # @return [MaskOtelSpansResult]
    # @raise [ArgumentError] if an unknown keyword is given
    def initialize(span_patches: {})
      super
    end
  end
end
