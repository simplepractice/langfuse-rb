# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Langfuse module score API parity" do
  describe ".create_score" do
    it "delegates the full score field set" do
      mock_client = instance_double(Langfuse::Client)
      allow(Langfuse).to receive(:client).and_return(mock_client)

      expect(mock_client).to receive(:create_score).with(
        name: "quality",
        value: 0.92,
        id: "score-001",
        trace_id: "trace-123",
        session_id: "session-789",
        observation_id: "observation-456",
        comment: "looks good",
        metadata: { source: "evaluator" },
        environment: "production",
        data_type: :numeric,
        dataset_run_id: "dataset-run-789",
        config_id: "config-abc"
      )

      Langfuse.create_score(
        name: "quality",
        value: 0.92,
        id: "score-001",
        trace_id: "trace-123",
        session_id: "session-789",
        observation_id: "observation-456",
        comment: "looks good",
        metadata: { source: "evaluator" },
        environment: "production",
        data_type: :numeric,
        dataset_run_id: "dataset-run-789",
        config_id: "config-abc"
      )
    end
  end

  describe "score API parity with Langfuse::Client" do
    it "exposes the expected create_score keyword arguments" do
      keyword_names = Langfuse.method(:create_score).parameters.filter_map do |type, name|
        name if type == :key
      end

      expect(keyword_names).to eq(
        %i[id trace_id session_id observation_id comment metadata environment data_type dataset_run_id config_id]
      )
    end

    it "matches create_score parameters" do
      expect(Langfuse.method(:create_score).parameters).to eq(
        Langfuse::Client.instance_method(:create_score).parameters
      )
    end

    it "matches score_active_observation parameters" do
      expect(Langfuse.method(:score_active_observation).parameters).to eq(
        Langfuse::Client.instance_method(:score_active_observation).parameters
      )
    end

    it "matches score_active_trace parameters" do
      expect(Langfuse.method(:score_active_trace).parameters).to eq(
        Langfuse::Client.instance_method(:score_active_trace).parameters
      )
    end

    it "matches flush_scores parameters" do
      expect(Langfuse.method(:flush_scores).parameters).to eq(
        Langfuse::Client.instance_method(:flush_scores).parameters
      )
    end
  end
end
