# frozen_string_literal: true

module Langfuse
  # Central masking chokepoint for tracing payload fields.
  #
  # Applies a user-provided mask callable to input, output, and metadata
  # before serialization. Fail-closed: if the mask raises, the entire
  # field is replaced with {FALLBACK}.
  #
  # @api private
  module Masking
    # Replacement string used when the mask callable raises
    FALLBACK = "<fully masked due to failed mask function>"

    # Apply the mask callable to a data value.
    #
    # @param data [Object, nil] The value to mask (input, output, or metadata)
    # @param mask [#call, nil] Callable receiving `data:` keyword; nil disables masking
    # @return [Object] Masked data, original data (when mask is nil/data is nil), or {FALLBACK}
    def self.apply(data, mask:)
      return data if mask.nil? || data.nil?

      mask.call(data: data)
    rescue StandardError => e
      Langfuse.configuration.logger.warn("Langfuse: Mask function failed: #{e.message}")
      FALLBACK
    end
  end
end
