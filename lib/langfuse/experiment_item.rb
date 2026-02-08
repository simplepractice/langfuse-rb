# frozen_string_literal: true

module Langfuse
  # Lightweight value object for local experiment data (passed via `data:` kwarg).
  # Unlike DatasetItemClient, these items have no server-side ID and cannot be
  # linked to dataset runs.
  ExperimentItem = Data.define(:input, :expected_output, :metadata) do
    def initialize(input:, expected_output:, metadata: nil)
      super
    end
  end
end
