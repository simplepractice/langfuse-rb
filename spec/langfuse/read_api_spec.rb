# frozen_string_literal: true

RSpec.describe Langfuse::ReadApi do
  let(:base_url) { "https://cloud.langfuse.com" }
  let(:api_client) do
    Langfuse::ApiClient.new(
      public_key: "pk_test_123",
      secret_key: "sk_test_456",
      base_url: base_url,
      timeout: 10
    )
  end

  let(:from_time) { Time.utc(2026, 7, 1, 0, 0, 0) }
  let(:to_time) { Time.utc(2026, 7, 2, 0, 0, 0) }

  describe "#list_observations" do
    let(:observations_response) do
      {
        "data" => [
          { "id" => "obs-1", "traceId" => "trace-1", "type" => "GENERATION" },
          { "id" => "obs-2", "traceId" => "trace-1", "type" => "SPAN" }
        ],
        "meta" => { "cursor" => "bmV4dC1wYWdl", "limit" => 50 }
      }
    end

    context "with a bounded read" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/observations")
          .with(query: { fromStartTime: from_time.iso8601, toStartTime: to_time.iso8601 })
          .to_return(
            status: 200,
            body: observations_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "preserves the full data and meta envelope" do
        result = api_client.list_observations(from_start_time: from_time, to_start_time: to_time)
        expect(result["data"].size).to eq(2)
        expect(result.dig("meta", "cursor")).to eq("bmV4dC1wYWdl")
      end

      it "serializes Time bounds to ISO 8601" do
        api_client.list_observations(from_start_time: from_time, to_start_time: to_time)
        expect(
          a_request(:get, "#{base_url}/api/public/v2/observations")
            .with(query: { fromStartTime: from_time.iso8601, toStartTime: to_time.iso8601 })
        ).to have_been_made.once
      end

      it "passes pre-formatted string bounds through unchanged" do
        api_client.list_observations(
          from_start_time: from_time.iso8601, to_start_time: to_time.iso8601
        )
        expect(
          a_request(:get, "#{base_url}/api/public/v2/observations")
            .with(query: { fromStartTime: from_time.iso8601, toStartTime: to_time.iso8601 })
        ).to have_been_made.once
      end
    end

    context "with filters and field selection" do
      let(:query) do
        {
          fromStartTime: from_time.iso8601, toStartTime: to_time.iso8601,
          fields: "core,basic,usage", cursor: "Y3Vyc29y", limit: "100",
          type: "GENERATION", userId: "user-1", name: "chat", level: "ERROR",
          parentObservationId: "parent-1", environment: "production",
          version: "1.0", expandMetadata: "key1,key2"
        }
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v2/observations")
          .with(query: query)
          .to_return(
            status: 200,
            body: observations_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "maps snake_case keywords to camelCase query params" do
        api_client.list_observations(
          from_start_time: from_time, to_start_time: to_time,
          fields: "core,basic,usage", cursor: "Y3Vyc29y", limit: 100,
          type: "GENERATION", user_id: "user-1", name: "chat", level: "ERROR",
          parent_observation_id: "parent-1", environment: "production",
          version: "1.0", expand_metadata: "key1,key2"
        )
        expect(
          a_request(:get, "#{base_url}/api/public/v2/observations").with(query: query)
        ).to have_been_made.once
      end
    end

    context "with a structured filter" do
      let(:filter_json) { '[{"type":"string","column":"id","operator":"=","value":"obs-1"}]' }

      before do
        stub_request(:get, "#{base_url}/api/public/v2/observations")
          .with(query: hash_including(filter: filter_json))
          .to_return(
            status: 200,
            body: observations_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "passes the filter JSON through to the query string" do
        api_client.list_observations(
          from_start_time: from_time, to_start_time: to_time, filter: filter_json
        )
        expect(
          a_request(:get, "#{base_url}/api/public/v2/observations")
            .with(query: hash_including(filter: filter_json))
        ).to have_been_made.once
      end
    end

    context "with a trace-scoped read" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/observations")
          .with(query: { traceId: "trace-1" })
          .to_return(
            status: 200,
            body: observations_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "allows omitting start-time bounds when trace_id is provided" do
        result = api_client.list_observations(trace_id: "trace-1")
        expect(result["data"].size).to eq(2)
      end
    end

    context "with an unbounded read" do
      it "rejects a read with no bounds and no trace_id" do
        expect { api_client.list_observations }
          .to raise_error(ArgumentError, /from_start_time and to_start_time are required/)
      end

      it "rejects a read missing one bound" do
        expect { api_client.list_observations(from_start_time: from_time) }
          .to raise_error(ArgumentError, /from_start_time and to_start_time are required/)
      end

      it "rejects a blank trace_id as absent" do
        expect { api_client.list_observations(trace_id: "  ") }
          .to raise_error(ArgumentError, /from_start_time and to_start_time are required/)
      end

      it "rejects blank string bounds as absent" do
        expect { api_client.list_observations(from_start_time: "", to_start_time: "") }
          .to raise_error(ArgumentError, /from_start_time and to_start_time are required/)
      end

      it "does not issue an HTTP request" do
        begin
          api_client.list_observations
        rescue ArgumentError
          nil
        end
        expect(a_request(:get, "#{base_url}/api/public/v2/observations")).not_to have_been_made
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/observations")
          .with(query: hash_including({}))
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect { api_client.list_observations(from_start_time: from_time, to_start_time: to_time) }
          .to raise_error(Langfuse::UnauthorizedError)
      end
    end

    context "when the endpoint is unavailable (self-hosted)" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/observations")
          .with(query: hash_including({}))
          .to_return(status: 404, body: { message: "Not found" }.to_json)
      end

      it "raises NotFoundError rather than falling back to legacy endpoints" do
        expect { api_client.list_observations(from_start_time: from_time, to_start_time: to_time) }
          .to raise_error(Langfuse::NotFoundError)
        expect(a_request(:get, "#{base_url}/api/public/traces")).not_to have_been_made
      end
    end
  end

  describe "#query_metrics" do
    let(:metrics_query) do
      {
        view: "observations",
        metrics: [{ measure: "count", aggregation: "count" }],
        fromTimestamp: from_time.iso8601,
        toTimestamp: to_time.iso8601
      }
    end
    let(:metrics_response) { { "data" => [{ "count_count" => "42" }] } }

    before do
      stub_request(:get, "#{base_url}/api/public/v2/metrics")
        .with(query: { query: JSON.generate(metrics_query) })
        .to_return(
          status: 200,
          body: metrics_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "JSON-encodes a Hash query into the query parameter" do
      result = api_client.query_metrics(query: metrics_query)
      expect(result["data"]).to eq([{ "count_count" => "42" }])
    end

    it "passes a pre-encoded JSON string through unchanged" do
      api_client.query_metrics(query: JSON.generate(metrics_query))
      expect(
        a_request(:get, "#{base_url}/api/public/v2/metrics")
          .with(query: { query: JSON.generate(metrics_query) })
      ).to have_been_made.once
    end

    it "rejects non-Hash, non-String queries" do
      expect { api_client.query_metrics(query: [1, 2]) }
        .to raise_error(ArgumentError, /query must be a Hash or JSON String/)
    end

    context "when authentication fails" do
      before do
        stub_request(:get, "#{base_url}/api/public/v2/metrics")
          .with(query: hash_including({}))
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect { api_client.query_metrics(query: metrics_query) }
          .to raise_error(Langfuse::UnauthorizedError)
      end
    end
  end

  describe "#list_scores" do
    let(:scores_response) do
      {
        "data" => [
          { "id" => "score-1", "name" => "quality", "dataType" => "NUMERIC", "value" => 0.85 },
          { "id" => "score-2", "name" => "passed", "dataType" => "BOOLEAN", "value" => true },
          { "id" => "score-3", "name" => "output", "dataType" => "CORRECTION", "value" => "fixed output" }
        ],
        "meta" => { "cursor" => "bmV4dA", "limit" => 50 }
      }
    end

    context "with a successful response" do
      before do
        stub_request(:get, "#{base_url}/api/public/v3/scores")
          .with(query: hash_including({}))
          .to_return(
            status: 200,
            body: scores_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "preserves the full data and meta envelope" do
        result = api_client.list_scores
        expect(result["data"].size).to eq(3)
        expect(result.dig("meta", "cursor")).to eq("bmV4dA")
      end

      it "preserves polymorphic score values" do
        values = api_client.list_scores["data"].map { |score| score["value"] }
        expect(values).to eq([0.85, true, "fixed output"])
      end
    end

    context "with filters" do
      let(:query) do
        {
          limit: "25", cursor: "Y3Vyc29y", fields: "subject,details",
          id: "score-1,score-2", name: "quality", source: "API",
          dataType: "CORRECTION", environment: "production",
          configId: "cfg-1", queueId: "queue-1", authorUserId: "user-1",
          traceId: "trace-1", observationId: "obs-1",
          fromTimestamp: from_time.iso8601, toTimestamp: to_time.iso8601
        }
      end

      before do
        stub_request(:get, "#{base_url}/api/public/v3/scores")
          .with(query: query)
          .to_return(
            status: 200,
            body: scores_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "maps snake_case keywords to camelCase query params" do
        api_client.list_scores(
          limit: 25, cursor: "Y3Vyc29y", fields: "subject,details",
          id: "score-1,score-2", name: "quality", source: "API",
          data_type: "CORRECTION", environment: "production",
          config_id: "cfg-1", queue_id: "queue-1", author_user_id: "user-1",
          trace_id: "trace-1", observation_id: "obs-1",
          from_timestamp: from_time, to_timestamp: to_time
        )
        expect(
          a_request(:get, "#{base_url}/api/public/v3/scores").with(query: query)
        ).to have_been_made.once
      end
    end

    context "with numeric value bounds" do
      before do
        stub_request(:get, "#{base_url}/api/public/v3/scores")
          .with(query: { dataType: "NUMERIC", valueMin: "0.5", valueMax: "1" })
          .to_return(
            status: 200,
            body: scores_response.to_json,
            headers: { "Content-Type" => "application/json" }
          )
      end

      it "sends valueMin and valueMax" do
        api_client.list_scores(data_type: "NUMERIC", value_min: 0.5, value_max: 1)
        expect(
          a_request(:get, "#{base_url}/api/public/v3/scores")
            .with(query: { dataType: "NUMERIC", valueMin: "0.5", valueMax: "1" })
        ).to have_been_made.once
      end
    end

    context "when authentication fails" do
      before do
        stub_request(:get, "#{base_url}/api/public/v3/scores")
          .with(query: hash_including({}))
          .to_return(status: 401, body: { message: "Unauthorized" }.to_json)
      end

      it "raises UnauthorizedError" do
        expect { api_client.list_scores }.to raise_error(Langfuse::UnauthorizedError)
      end
    end
  end

  describe "Client delegation" do
    let(:config) do
      Langfuse::Config.new do |c|
        c.public_key = "pk_test_123"
        c.secret_key = "sk_test_456"
        c.base_url = base_url
      end
    end
    let(:client) { Langfuse::Client.new(config) }

    before do
      stub_request(:get, %r{#{base_url}/api/public/(v2/observations|v2/metrics|v3/scores)})
        .to_return(
          status: 200,
          body: { "data" => [], "meta" => {} }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "exposes list_observations on the flat client API" do
      client.list_observations(from_start_time: from_time, to_start_time: to_time)
      expect(a_request(:get, %r{/api/public/v2/observations})).to have_been_made.once
    end

    it "exposes query_metrics on the flat client API" do
      client.query_metrics(query: { view: "observations" })
      expect(a_request(:get, %r{/api/public/v2/metrics})).to have_been_made.once
    end

    it "exposes list_scores on the flat client API" do
      client.list_scores(trace_id: "trace-1")
      expect(a_request(:get, %r{/api/public/v3/scores})).to have_been_made.once
    end
  end
end
