# frozen_string_literal: true

require "faraday"
require "uri"

module Langfuse
  module Resources
    # Dataset and dataset-run API resource operations.
    #
    # @api private
    class Datasets # rubocop:disable Metrics/ClassLength
      # @param connection [#call] Callable returning a Faraday connection
      # @param handle_response [#call] Response handler callable
      # @param handle_delete_dataset_item_response [#call] Dataset item delete response handler
      # @param with_error_handling [#call] Faraday error wrapper callable
      # @param logger [Logger] Logger for transport errors
      # @return [Datasets]
      def initialize(connection:, handle_response:, handle_delete_dataset_item_response:, with_error_handling:, logger:)
        @connection = connection
        @handle_response = handle_response
        @handle_delete_dataset_item_response = handle_delete_dataset_item_response
        @with_error_handling = with_error_handling
        @logger = logger
      end

      # Create a dataset run item.
      #
      # @param dataset_item_id [String] Dataset item ID
      # @param run_name [String] Run name
      # @param trace_id [String, nil] Optional trace ID
      # @param observation_id [String, nil] Optional observation ID
      # @param metadata [Hash, nil] Optional metadata
      # @param run_description [String, nil] Optional run description
      # @return [Hash] Created dataset run item
      def create_dataset_run_item(dataset_item_id:, run_name:, trace_id: nil,
                                  observation_id: nil, metadata: nil, run_description: nil)
        with_error_handling do
          payload = { datasetItemId: dataset_item_id, runName: run_name }
          payload[:traceId] = trace_id if trace_id
          payload[:observationId] = observation_id if observation_id
          payload[:metadata] = metadata if metadata
          payload[:runDescription] = run_description if run_description

          handle_response(connection.post("/api/public/dataset-run-items", payload))
        end
      end

      # Fetch a dataset run by dataset and run name.
      #
      # @param dataset_name [String] Dataset name
      # @param run_name [String] Run name
      # @return [Hash] Dataset run data
      def get_dataset_run(dataset_name:, run_name:)
        with_error_handling do
          handle_response(connection.get(dataset_run_path(dataset_name: dataset_name, run_name: run_name)))
        end
      end

      # List dataset runs.
      #
      # @param dataset_name [String] Dataset name
      # @param page [Integer, nil] Optional page number
      # @param limit [Integer, nil] Optional page size
      # @return [Array<Hash>] Dataset run hashes
      def list_dataset_runs(dataset_name:, page: nil, limit: nil)
        result = list_dataset_runs_paginated(dataset_name: dataset_name, page: page, limit: limit)
        result["data"] || []
      end

      # List dataset runs with pagination metadata.
      #
      # @param dataset_name [String] Dataset name
      # @param page [Integer, nil] Optional page number
      # @param limit [Integer, nil] Optional page size
      # @return [Hash] Full response hash
      def list_dataset_runs_paginated(dataset_name:, page: nil, limit: nil)
        with_error_handling do
          response = connection.get(dataset_runs_path(dataset_name), { page: page, limit: limit }.compact)
          handle_response(response)
        end
      end

      # Delete a dataset run.
      #
      # @param dataset_name [String] Dataset name
      # @param run_name [String] Run name
      # @return [Hash, nil] Delete response body or nil for 204
      def delete_dataset_run(dataset_name:, run_name:)
        with_error_handling do
          response = connection.delete(dataset_run_path(dataset_name: dataset_name, run_name: run_name))
          response.status == 204 ? nil : handle_response(response)
        end
      end

      # List datasets.
      #
      # @param page [Integer, nil] Optional page number
      # @param limit [Integer, nil] Optional page size
      # @return [Array<Hash>] Dataset metadata hashes
      def list_datasets(page: nil, limit: nil)
        with_error_handling do
          result = handle_response(connection.get("/api/public/v2/datasets", { page: page, limit: limit }.compact))
          result["data"] || []
        end
      end

      # Fetch a dataset by name.
      #
      # @param name [String] Dataset name
      # @return [Hash] Dataset data
      def get_dataset(name)
        with_error_handling do
          response = connection.get("/api/public/v2/datasets/#{URI.encode_uri_component(name)}")
          handle_response(response)
        end
      end

      # Create a dataset.
      #
      # @param name [String] Dataset name
      # @param description [String, nil] Optional description
      # @param metadata [Hash, nil] Optional metadata
      # @return [Hash] Created dataset data
      def create_dataset(name:, description: nil, metadata: nil)
        with_error_handling do
          payload = { name: name, description: description, metadata: metadata }.compact
          handle_response(connection.post("/api/public/v2/datasets", payload))
        end
      end

      # Create or upsert a dataset item.
      #
      # @param options [Hash] Dataset item payload options
      # @return [Hash] Created dataset item data
      def create_dataset_item(**options)
        with_error_handling do
          response = connection.post("/api/public/dataset-items", build_dataset_item_payload(**options))
          handle_response(response)
        end
      end

      # Fetch a dataset item by ID.
      #
      # @param id [String] Dataset item ID
      # @return [Hash] Dataset item data
      def get_dataset_item(id)
        with_error_handling do
          response = connection.get("/api/public/dataset-items/#{URI.encode_uri_component(id)}")
          handle_response(response)
        end
      end

      # List dataset items.
      #
      # @param options [Hash] Dataset item list filters
      # @return [Array<Hash>] Dataset item hashes
      def list_dataset_items(**)
        result = list_dataset_items_paginated(**)
        result["data"] || []
      end

      # List dataset items with pagination metadata.
      #
      # @param dataset_name [String] Dataset name
      # @param page [Integer, nil] Optional page number
      # @param limit [Integer, nil] Optional page size
      # @param source_trace_id [String, nil] Optional source trace filter
      # @param source_observation_id [String, nil] Optional source observation filter
      # @return [Hash] Full response hash
      def list_dataset_items_paginated(dataset_name:, page: nil, limit: nil,
                                       source_trace_id: nil, source_observation_id: nil)
        with_error_handling do
          params = build_dataset_items_params(
            dataset_name: dataset_name, page: page, limit: limit,
            source_trace_id: source_trace_id, source_observation_id: source_observation_id
          )
          handle_response(connection.get("/api/public/dataset-items", params))
        end
      end

      # Delete a dataset item by ID.
      #
      # @param id [String] Dataset item ID
      # @return [Hash] Delete response body
      def delete_dataset_item(id)
        response = connection.delete("/api/public/dataset-items/#{URI.encode_uri_component(id)}")
        handle_delete_dataset_item_response(response, id)
      rescue Faraday::RetriableResponse => e
        logger.error("Faraday error: Retries exhausted - #{e.response.status}")
        handle_delete_dataset_item_response(e.response, id)
      rescue Faraday::Error => e
        logger.error("Faraday error: #{e.message}")
        raise ApiError, "HTTP request failed: #{e.message}"
      end

      private

      attr_reader :logger

      def build_dataset_item_payload(**options)
        { datasetName: options.fetch(:dataset_name) }.tap do |payload|
          add_dataset_item_fields(payload, options)
          add_source_fields(payload, options)
        end
      end

      def add_dataset_item_fields(payload, options)
        payload[:id] = options[:id] if options[:id]
        payload[:input] = options[:input] if options[:input]
        payload[:expectedOutput] = options[:expected_output] if options[:expected_output]
        payload[:metadata] = options[:metadata] if options[:metadata]
      end

      def add_source_fields(payload, options)
        payload[:sourceTraceId] = options[:source_trace_id] if options[:source_trace_id]
        payload[:sourceObservationId] = options[:source_observation_id] if options[:source_observation_id]
        payload[:status] = options[:status].to_s.upcase if options[:status]
      end

      def build_dataset_items_params(dataset_name:, page:, limit:, source_trace_id:, source_observation_id:)
        {
          datasetName: dataset_name,
          page: page,
          limit: limit,
          sourceTraceId: source_trace_id,
          sourceObservationId: source_observation_id
        }.compact
      end

      def dataset_runs_path(dataset_name)
        encoded_name = URI.encode_uri_component(dataset_name)
        "/api/public/datasets/#{encoded_name}/runs"
      end

      def dataset_run_path(dataset_name:, run_name:)
        encoded_run_name = URI.encode_uri_component(run_name)
        "#{dataset_runs_path(dataset_name)}/#{encoded_run_name}"
      end

      def connection
        @connection.call
      end

      def handle_response(response)
        @handle_response.call(response)
      end

      def handle_delete_dataset_item_response(response, id)
        @handle_delete_dataset_item_response.call(response, id)
      end

      def with_error_handling(&)
        @with_error_handling.call(&)
      end
    end
  end
end
