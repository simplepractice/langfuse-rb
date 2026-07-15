# frozen_string_literal: true

require "json"

module Langfuse
  # Read endpoints for the current Langfuse query surface.
  #
  # Implements the Cloud-only v2 observation and metrics reads plus the v3
  # scores read. Mixed into {ApiClient}, whose private +request+ helper
  # provides HTTP transport and error handling.
  #
  # @note The v2 observations and v2 metrics endpoints are only available on
  #   Langfuse Cloud. There is no fallback to legacy endpoints because their
  #   response and pagination semantics differ.
  module ReadApi
    # Ruby keyword argument -> camelCase query parameter mappings. Start-time
    # bounds are handled separately because they need ISO 8601 formatting.
    OBSERVATION_QUERY_PARAMS = {
      trace_id: :traceId, fields: :fields, cursor: :cursor, limit: :limit,
      filter: :filter, name: :name, user_id: :userId, type: :type,
      level: :level, parent_observation_id: :parentObservationId,
      environment: :environment, version: :version,
      expand_metadata: :expandMetadata
    }.freeze
    private_constant :OBSERVATION_QUERY_PARAMS

    SCORE_QUERY_PARAMS = {
      limit: :limit, cursor: :cursor, fields: :fields, id: :id, name: :name,
      source: :source, data_type: :dataType, environment: :environment,
      config_id: :configId, queue_id: :queueId, author_user_id: :authorUserId,
      value: :value, value_min: :valueMin, value_max: :valueMax,
      trace_id: :traceId, session_id: :sessionId,
      observation_id: :observationId, experiment_id: :experimentId
    }.freeze
    private_constant :SCORE_QUERY_PARAMS

    # List observations with cursor-based pagination and field selection
    #
    # Delegates to +GET /api/public/v2/observations+ (Langfuse Cloud only).
    # Returns observation rows, not reconstructed trace objects. The full
    # response envelope is preserved: +"data"+ holds the observation rows and
    # +"meta"+ holds the pagination cursor for the next page.
    #
    # Broad reads must be bounded: unless +trace_id+ narrows the query, both
    # +from_start_time+ and +to_start_time+ are required.
    #
    # @param from_start_time [Time, String, nil] Inclusive lower bound on observation start time
    # @param to_start_time [Time, String, nil] Exclusive upper bound on observation start time
    # @param trace_id [String, nil] Filter by trace ID
    # @param fields [String, nil] Comma-separated field groups to include
    #   (core, basic, time, io, metadata, model, usage, prompt, metrics, trace_context)
    # @param cursor [String, nil] Cursor from the previous response's meta for the next page
    # @param limit [Integer, nil] Items per page (max 1000, default 50)
    # @param filter [String, nil] JSON string with structured filter conditions;
    #   takes precedence over individual query parameter filters
    # @param name [String, nil] Filter by observation name
    # @param user_id [String, nil] Filter by user ID
    # @param type [String, nil] Filter by observation type (e.g. "GENERATION", "SPAN")
    # @param level [String, nil] Filter by level (e.g. "DEFAULT", "ERROR")
    # @param parent_observation_id [String, nil] Filter by parent observation ID
    # @param environment [String, nil] Filter by environment
    # @param version [String, nil] Filter by observation version
    # @param expand_metadata [String, nil] Comma-separated metadata keys to return non-truncated
    # @return [Hash] Full response hash with "data" rows and "meta" cursor info
    # @raise [ArgumentError] if the read is unbounded (no trace_id and missing start-time bounds)
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors (including non-Cloud deployments)
    #
    # @example Bounded read of recent generations
    #   page = api_client.list_observations(
    #     from_start_time: Time.now - 3600,
    #     to_start_time: Time.now,
    #     type: "GENERATION",
    #     fields: "core,basic,usage"
    #   )
    #   page["data"].each { |obs| puts obs["id"] }
    #   next_cursor = page.dig("meta", "cursor")
    # rubocop:disable Metrics/ParameterLists
    def list_observations(from_start_time: nil, to_start_time: nil, trace_id: nil,
                          fields: nil, cursor: nil, limit: nil, filter: nil,
                          name: nil, user_id: nil, type: nil, level: nil,
                          parent_observation_id: nil, environment: nil,
                          version: nil, expand_metadata: nil)
      validate_bounded_observation_read!(trace_id, from_start_time, to_start_time)
      params = build_observations_params(
        from_start_time: from_start_time, to_start_time: to_start_time,
        trace_id: trace_id, fields: fields, cursor: cursor, limit: limit,
        filter: filter, name: name, user_id: user_id, type: type, level: level,
        parent_observation_id: parent_observation_id, environment: environment,
        version: version, expand_metadata: expand_metadata
      )
      request(:get, "/api/public/v2/observations", params: params)
    end
    # rubocop:enable Metrics/ParameterLists

    # Query aggregate metrics (Langfuse Cloud only)
    #
    # Delegates to +GET /api/public/v2/metrics+. Supports the +observations+,
    # +scores-numeric+, and +scores-categorical+ views.
    #
    # @param query [Hash, String] Metrics query. A Hash is JSON-encoded into
    #   the endpoint's +query+ parameter; a pre-encoded JSON String is passed
    #   through unchanged.
    # @return [Hash] The parsed metrics response
    # @raise [ArgumentError] if query is neither a Hash nor a String
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors (including non-Cloud deployments)
    #
    # @example Count observations by name
    #   api_client.query_metrics(query: {
    #     view: "observations",
    #     metrics: [{ measure: "count", aggregation: "count" }],
    #     dimensions: [{ field: "name" }],
    #     fromTimestamp: "2026-07-01T00:00:00Z",
    #     toTimestamp: "2026-07-02T00:00:00Z"
    #   })
    def query_metrics(query:)
      request(:get, "/api/public/v2/metrics", params: { query: encode_metrics_query(query) })
    end

    # List scores with polymorphic values (v3)
    #
    # Delegates to +GET /api/public/v3/scores+. The full response envelope is
    # preserved: +"data"+ holds score rows and +"meta"+ holds the pagination
    # cursor. Score values are polymorphic by +dataType+: NUMERIC scores return
    # numbers, BOOLEAN scores return booleans, and CATEGORICAL, TEXT, and
    # CORRECTION scores return strings.
    #
    # @param limit [Integer, nil] Items per page (max 100, default 50)
    # @param cursor [String, nil] Cursor from the previous response's meta for the next page
    # @param fields [String, nil] Comma-separated field groups in addition to core
    #   (details, subject, annotation)
    # @param id [String, nil] Comma-separated score IDs to filter by
    # @param name [String, nil] Comma-separated score names to filter by
    # @param source [String, nil] Comma-separated score sources (e.g. API, ANNOTATION, EVAL)
    # @param data_type [String, nil] Comma-separated data types
    #   (NUMERIC, BOOLEAN, CATEGORICAL, TEXT, CORRECTION)
    # @param environment [String, nil] Comma-separated environments to filter by
    # @param config_id [String, nil] Comma-separated score config IDs
    # @param queue_id [String, nil] Comma-separated annotation queue IDs
    # @param author_user_id [String, nil] Comma-separated author user IDs
    # @param value [String, nil] Comma-separated exact values (requires a single
    #   NUMERIC, BOOLEAN, or CATEGORICAL data_type)
    # @param value_min [Numeric, nil] Inclusive lower bound (requires data_type: "NUMERIC")
    # @param value_max [Numeric, nil] Inclusive upper bound (requires data_type: "NUMERIC")
    # @param trace_id [String, nil] Comma-separated trace IDs (mutually exclusive
    #   with session_id and experiment_id)
    # @param session_id [String, nil] Comma-separated session IDs
    # @param observation_id [String, nil] Comma-separated observation IDs (requires trace_id)
    # @param experiment_id [String, nil] Comma-separated dataset run (experiment) IDs
    # @param from_timestamp [Time, String, nil] Inclusive lower bound on score timestamp
    # @param to_timestamp [Time, String, nil] Exclusive upper bound on score timestamp
    # @return [Hash] Full response hash with "data" rows and "meta" cursor info
    # @raise [UnauthorizedError] if authentication fails
    # @raise [ApiError] for other API errors
    #
    # @example Read corrections for a trace
    #   page = api_client.list_scores(trace_id: trace_id, data_type: "CORRECTION", fields: "subject,details")
    #   page["data"].each { |score| puts score["value"] }
    # rubocop:disable Metrics/ParameterLists
    def list_scores(limit: nil, cursor: nil, fields: nil, id: nil, name: nil,
                    source: nil, data_type: nil, environment: nil, config_id: nil,
                    queue_id: nil, author_user_id: nil, value: nil, value_min: nil,
                    value_max: nil, trace_id: nil, session_id: nil,
                    observation_id: nil, experiment_id: nil,
                    from_timestamp: nil, to_timestamp: nil)
      params = build_scores_params(
        limit: limit, cursor: cursor, fields: fields, id: id, name: name,
        source: source, data_type: data_type, environment: environment,
        config_id: config_id, queue_id: queue_id, author_user_id: author_user_id,
        value: value, value_min: value_min, value_max: value_max,
        trace_id: trace_id, session_id: session_id, observation_id: observation_id,
        experiment_id: experiment_id, from_timestamp: from_timestamp, to_timestamp: to_timestamp
      )
      request(:get, "/api/public/v3/scores", params: params)
    end
    # rubocop:enable Metrics/ParameterLists

    private

    # v2 observation reads must always be bounded; an unbounded scan over the
    # events table is rejected here rather than issued silently. Only values
    # matching the documented query contract can satisfy the bound.
    def validate_bounded_observation_read!(trace_id, from_start_time, to_start_time)
      return if non_empty_string?(trace_id)
      return if valid_query_time?(from_start_time) && valid_query_time?(to_start_time)

      raise ArgumentError,
            "from_start_time and to_start_time are required unless trace_id is provided"
    end

    def valid_query_time?(value)
      non_empty_string?(format_query_time(value))
    end

    def non_empty_string?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    def build_observations_params(**options)
      camelize_params(OBSERVATION_QUERY_PARAMS, options).merge(
        fromStartTime: format_query_time(options[:from_start_time]),
        toStartTime: format_query_time(options[:to_start_time])
      ).compact
    end

    def build_scores_params(**options)
      camelize_params(SCORE_QUERY_PARAMS, options).merge(
        fromTimestamp: format_query_time(options[:from_timestamp]),
        toTimestamp: format_query_time(options[:to_timestamp])
      ).compact
    end

    def camelize_params(mapping, options)
      mapping.to_h { |ruby_key, api_key| [api_key, options[ruby_key]] }
    end

    def encode_metrics_query(query)
      case query
      when Hash then JSON.generate(query)
      when String then query
      else raise ArgumentError, "query must be a Hash or JSON String, got #{query.class}"
      end
    end

    # Accepts Time-like values or pre-formatted ISO 8601 strings.
    def format_query_time(value)
      value.respond_to?(:iso8601) ? value.iso8601 : value
    end
  end
end
