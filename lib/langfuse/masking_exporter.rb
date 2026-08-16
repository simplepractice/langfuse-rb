# frozen_string_literal: true

require "opentelemetry/sdk"
require_relative "otel_span_batch"
require_relative "otel_span_patch_applier"

module Langfuse
  # Export-stage masking wrapper around the Langfuse OTLP exporter.
  #
  # Only the copy exported to Langfuse is transformed. Original span data and
  # any other OpenTelemetry exporter remain unchanged.
  #
  # @api private
  class MaskingExporter
    SUCCESS = OpenTelemetry::SDK::Trace::Export::SUCCESS
    private_constant :SUCCESS

    # Distinguishes "the hook raised" from a hook that legitimately returned nil.
    # A constant rather than a memoized ivar because BatchSpanProcessor#force_flush
    # exports on the caller's thread while the background thread may also be exporting.
    HOOK_FAILURE = Object.new.freeze
    private_constant :HOOK_FAILURE

    # @param delegate [#export, #force_flush, #shutdown] Langfuse OTLP exporter
    # @param hook [#call] configured mask_otel_spans callable
    # @param logger [Logger]
    def initialize(delegate:, hook:, logger:)
      @delegate = delegate
      @hook = hook
      @logger = logger
      @patch_applier = OtelSpanPatchApplier.new(logger: logger)
    end

    # Mask the batch and delegate export.
    #
    # @param span_data [Enumerable<OpenTelemetry::SDK::Trace::SpanData>]
    # @param timeout [Numeric, nil]
    # @return [Integer] OpenTelemetry export result code
    def export(span_data, timeout: nil)
      masked_spans = mask_batch(span_data.to_a)
      return SUCCESS if masked_spans.nil? || masked_spans.empty?

      @delegate.export(masked_spans, timeout: timeout)
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

    # Returns nil to drop the whole Langfuse batch, otherwise the spans to export.
    def mask_batch(span_data)
      batch = OtelSpanBatch.new(span_data: span_data, logger: @logger)
      return [] if batch.empty?

      result = call_hook(batch)
      return if result.equal?(HOOK_FAILURE)
      return batch.spans if result.nil?
      return unless valid_result?(result, batch)

      batch.apply(result.span_patches, patch_applier: @patch_applier)
    end

    def call_hook(batch)
      @hook.call(params: batch.masking_params)
    rescue StandardError => e
      # Hook exception messages can contain the sensitive values being masked.
      @logger.error("Langfuse mask_otel_spans raised #{e.class}; #{dropping_batch(batch)}")
      HOOK_FAILURE
    end

    def valid_result?(result, batch)
      unless result.is_a?(MaskOtelSpansResult) && result.span_patches.is_a?(Hash)
        @logger.error("Langfuse mask_otel_spans returned an invalid result; #{dropping_batch(batch)}")
        return false
      end

      return true if result.span_patches.each_key.all? { |identifier| batch.include_identifier?(identifier) }

      @logger.error(
        "Langfuse mask_otel_spans returned a patch for an unknown span identifier; #{dropping_batch(batch)}"
      )
      false
    end

    def dropping_batch(batch)
      "dropping the Langfuse export batch of #{batch.size} spans"
    end
  end
end
