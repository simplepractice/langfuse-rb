# frozen_string_literal: true

module Langfuse
  # Implements disabled score operations without validation or network access.
  #
  # @api private
  class NoopScoreClient
    # @param _options [Hash] Ignored score attributes
    # @return [nil]
    def create(**_options)
      nil
    end

    # @param _options [Hash] Ignored score attributes
    # @return [nil]
    def create!(**_options)
      nil
    end

    # @param _options [Hash] Ignored score attributes
    # @return [nil]
    def score_active_observation(**_options)
      nil
    end

    # @param _options [Hash] Ignored score attributes
    # @return [nil]
    def score_active_trace(**_options)
      nil
    end

    # @return [nil]
    def flush
      nil
    end

    # @return [nil]
    def shutdown
      nil
    end
  end
end
