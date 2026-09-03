# frozen_string_literal: true

require "digest"
require "securerandom"

module Langfuse
  # Builds the OpenTelemetry attributes that identify v4 experiment observations.
  #
  # @api private
  module ExperimentAttributes
    ENVIRONMENT = "sdk-experiment"

    def self.generate_experiment_id
      SecureRandom.hex(8)
    end

    def self.generate_item_id(input)
      serialized_input = OtelAttributes.serialize(input, preserve_strings: true) || input.to_s
      Digest::SHA256.hexdigest(serialized_input)[0, 16]
    end

    # rubocop:disable Metrics/ParameterLists
    def self.propagated(experiment_id:, run_name:, item_id:, root_observation_id:,
                        dataset_id: nil, experiment_metadata: nil, item_metadata: nil, mask: nil)
      attributes = {
        OtelAttributes::EXPERIMENT_ID => experiment_id,
        OtelAttributes::EXPERIMENT_NAME => run_name,
        OtelAttributes::EXPERIMENT_DATASET_ID => dataset_id,
        OtelAttributes::EXPERIMENT_ITEM_ID => item_id,
        OtelAttributes::EXPERIMENT_ITEM_ROOT_OBSERVATION_ID => root_observation_id,
        OtelAttributes::ENVIRONMENT => ENVIRONMENT
      }.compact
      attributes.merge!(masked_metadata(experiment_metadata, OtelAttributes::EXPERIMENT_METADATA, mask))
      attributes.merge!(masked_metadata(item_metadata, OtelAttributes::EXPERIMENT_ITEM_METADATA, mask))
    end
    # rubocop:enable Metrics/ParameterLists

    def self.root(description:, expected_output:, mask: nil)
      masked_output = Masking.apply(expected_output, mask: mask)
      {
        OtelAttributes::EXPERIMENT_DESCRIPTION => description,
        OtelAttributes::EXPERIMENT_ITEM_EXPECTED_OUTPUT =>
          OtelAttributes.serialize(masked_output, preserve_strings: true)
      }.compact
    end

    def self.observation_metadata(name:, run_name:, experiment_metadata:, item_metadata:,
                                  dataset_id: nil, dataset_item_id: nil)
      metadata = hash_metadata(item_metadata).merge(hash_metadata(experiment_metadata))
      metadata[:experiment_name] = name
      metadata[:experiment_run_name] = run_name
      metadata[:dataset_id] = dataset_id if dataset_id
      metadata[:dataset_item_id] = dataset_item_id if dataset_item_id
      metadata
    end

    def self.masked_metadata(metadata, prefix, mask)
      OtelAttributes.flatten_metadata(Masking.apply(metadata, mask: mask), prefix)
    end
    private_class_method :masked_metadata

    def self.hash_metadata(metadata)
      metadata.is_a?(Hash) ? metadata : {}
    end
    private_class_method :hash_metadata
  end
end
