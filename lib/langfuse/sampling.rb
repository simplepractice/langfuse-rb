# frozen_string_literal: true

module Langfuse
  # Shared sampling helpers for trace and score emission.
  #
  # @api private
  module Sampling
    module_function

    # Build the sampler used by both trace export and trace-linked score emission.
    #
    # @param sample_rate [Float] Sampling rate from 0.0 to 1.0
    # @return [OpenTelemetry::SDK::Trace::Samplers::TraceIdRatioBased, nil]
    def build_sampler(sample_rate)
      return nil if sample_rate >= 1.0

      OpenTelemetry::SDK::Trace::Samplers::TraceIdRatioBased.new(sample_rate)
    end
  end
end
