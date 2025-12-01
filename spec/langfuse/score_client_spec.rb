# frozen_string_literal: true

require "opentelemetry/sdk"

RSpec.describe Langfuse::ScoreClient do
  subject(:score_client) { described_class.new(api_client: api_client, config: config) }

  let(:api_client) { instance_double(Langfuse::ApiClient) }
  let(:config) do
    Langfuse::Config.new do |c|
      c.public_key = "pk_test_123"
      c.secret_key = "sk_test_456"
      c.base_url = "https://cloud.langfuse.com"
      c.batch_size = 5
      c.flush_interval = 10
      c.logger = Logger.new(StringIO.new)
    end
  end

  before do
    # Stub ingestion endpoint
    stub_request(:post, "https://cloud.langfuse.com/api/public/ingestion")
      .to_return(status: 200, body: "", headers: {})
  end

  after do
    score_client.shutdown
  end

  describe "#initialize" do
    it "creates a score client" do
      expect(score_client).to be_a(described_class)
    end

    it "initializes with api_client and config" do
      expect(score_client.api_client).to eq(api_client)
      expect(score_client.config).to eq(config)
    end

    it "starts flush timer thread" do
      # Give thread a moment to start
      sleep(0.1)
      expect(score_client.instance_variable_get(:@flush_thread)).to be_alive
    end
  end

  describe "#create" do
    context "with valid numeric score" do
      it "queues the score event" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            type: "score-create",
                                                            body: hash_including(
                                                              name: "quality",
                                                              value: 0.85,
                                                              dataType: "NUMERIC"
                                                            )
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85, trace_id: "abc123", data_type: :numeric)
        score_client.flush
      end

      it "includes trace_id when provided" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(traceId: "abc123")
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85, trace_id: "abc123")
        score_client.flush
      end

      it "includes observation_id when provided" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(observationId: "def456")
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85, observation_id: "def456")
        score_client.flush
      end

      it "includes comment and metadata when provided" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(
                                                              comment: "High quality",
                                                              metadata: { source: "manual" }
                                                            )
                                                          )
                                                        ))

        score_client.create(
          name: "quality",
          value: 0.85,
          comment: "High quality",
          metadata: { source: "manual" }
        )
        score_client.flush
      end
    end

    context "with boolean score" do
      it "normalizes true to 1" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(
                                                              value: 1,
                                                              dataType: "BOOLEAN"
                                                            )
                                                          )
                                                        ))

        score_client.create(name: "passed", value: true, data_type: :boolean)
        score_client.flush
      end

      it "normalizes false to 0" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(
                                                              value: 0,
                                                              dataType: "BOOLEAN"
                                                            )
                                                          )
                                                        ))

        score_client.create(name: "passed", value: false, data_type: :boolean)
        score_client.flush
      end

      it "normalizes integer 1 to 1" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(body: hash_including(value: 1))
                                                        ))

        score_client.create(name: "passed", value: 1, data_type: :boolean)
        score_client.flush
      end

      it "normalizes integer 0 to 0" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(body: hash_including(value: 0))
                                                        ))

        score_client.create(name: "passed", value: 0, data_type: :boolean)
        score_client.flush
      end
    end

    context "with categorical score" do
      it "accepts string values" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(
                                                              value: "high",
                                                              dataType: "CATEGORICAL"
                                                            )
                                                          )
                                                        ))

        score_client.create(name: "category", value: "high", data_type: :categorical)
        score_client.flush
      end
    end

    context "with validation errors" do
      it "raises ArgumentError for missing name" do
        expect do
          score_client.create(name: nil, value: 0.85)
        end.to raise_error(ArgumentError, "name is required")
      end

      it "raises ArgumentError for empty name" do
        expect do
          score_client.create(name: "", value: 0.85)
        end.to raise_error(ArgumentError, "name is required")
      end

      it "raises ArgumentError for non-string name" do
        expect do
          score_client.create(name: 123, value: 0.85)
        end.to raise_error(ArgumentError, "name must be a String")
      end

      it "raises ArgumentError for non-numeric value with numeric data_type" do
        expect do
          score_client.create(name: "quality", value: "not a number", data_type: :numeric)
        end.to raise_error(ArgumentError, /Numeric value must be Numeric/)
      end

      it "raises ArgumentError for invalid boolean value" do
        expect do
          score_client.create(name: "passed", value: "yes", data_type: :boolean)
        end.to raise_error(ArgumentError, %r{Boolean value must be true/false or 0/1})
      end

      it "raises ArgumentError for non-string categorical value" do
        expect do
          score_client.create(name: "category", value: 123, data_type: :categorical)
        end.to raise_error(ArgumentError, /Categorical value must be a String/)
      end

      it "raises ArgumentError for invalid data_type" do
        expect do
          score_client.create(name: "quality", value: 0.85, data_type: :invalid)
        end.to raise_error(ArgumentError, "Invalid data_type: invalid")
      end
    end

    context "with batching" do
      it "flushes automatically when batch_size is reached" do
        expect(api_client).to receive(:send_batch).once

        # Create batch_size scores
        config.batch_size.times do |i|
          score_client.create(name: "score_#{i}", value: i)
        end
        # Give flush a moment to complete
        sleep(0.1)
      end

      it "batches multiple scores together" do
        expect(api_client).to receive(:send_batch) do |events|
          expect(events.length).to eq(3)
        end

        3.times do |i|
          score_client.create(name: "score_#{i}", value: i)
        end
        score_client.flush
      end
    end
  end

  describe "#score_active_observation" do
    let(:tracer) { OpenTelemetry.tracer_provider.tracer("test") }
    let(:span) { tracer.start_span("test-span") }
    let(:span_context) { span.context }

    it "extracts trace_id and observation_id from active span" do
      expect(api_client).to receive(:send_batch).with(array_including(
                                                        hash_including(
                                                          body: hash_including(
                                                            traceId: span_context.trace_id.unpack1("H*"),
                                                            observationId: span_context.span_id.unpack1("H*")
                                                          )
                                                        )
                                                      ))

      OpenTelemetry::Context.with_current(
        OpenTelemetry::Trace.context_with_span(span)
      ) do
        score_client.score_active_observation(name: "accuracy", value: 0.92)
        score_client.flush
      end
    end

    it "raises ArgumentError when no active span" do
      expect do
        score_client.score_active_observation(name: "accuracy", value: 0.92)
      end.to raise_error(ArgumentError, "No active OpenTelemetry span found")
    end
  end

  describe "#score_active_trace" do
    let(:tracer) { OpenTelemetry.tracer_provider.tracer("test") }
    let(:span) { tracer.start_span("test-span") }
    let(:span_context) { span.context }

    it "extracts trace_id from active span" do
      expect(api_client).to receive(:send_batch).with(array_including(
                                                        hash_including(
                                                          body: hash_including(
                                                            traceId: span_context.trace_id.unpack1("H*")
                                                          )
                                                        )
                                                      ))

      OpenTelemetry::Context.with_current(
        OpenTelemetry::Trace.context_with_span(span)
      ) do
        score_client.score_active_trace(name: "overall_quality", value: 5)
        score_client.flush
      end
    end

    it "raises ArgumentError when no active span" do
      expect do
        score_client.score_active_trace(name: "overall_quality", value: 5)
      end.to raise_error(ArgumentError, "No active OpenTelemetry span found")
    end
  end

  describe "#flush" do
    it "sends all queued events" do
      expect(api_client).to receive(:send_batch).with(array_including(
                                                        hash_including(body: hash_including(name: "score1")),
                                                        hash_including(body: hash_including(name: "score2"))
                                                      ))

      score_client.create(name: "score1", value: 1)
      score_client.create(name: "score2", value: 2)
      score_client.flush
    end

    it "does nothing when queue is empty" do
      expect(api_client).not_to receive(:send_batch)
      score_client.flush
    end

    it "handles API errors silently" do
      allow(api_client).to receive(:send_batch).and_raise(Langfuse::ApiError, "API error")

      expect do
        score_client.create(name: "score1", value: 1)
        score_client.flush
      end.not_to raise_error
    end
  end

  describe "#shutdown" do
    it "stops flush timer thread" do
      flush_thread = score_client.instance_variable_get(:@flush_thread)
      expect(flush_thread).to be_alive

      score_client.shutdown

      # Give thread a moment to stop
      sleep(0.1)
      expect(flush_thread).not_to be_alive
    end

    it "flushes remaining events" do
      expect(api_client).to receive(:send_batch).once

      score_client.create(name: "score1", value: 1)
      score_client.shutdown
    end

    it "can be called multiple times safely" do
      expect do
        score_client.shutdown
        score_client.shutdown
      end.not_to raise_error
    end
  end

  describe "thread safety" do
    it "handles concurrent score creation" do
      expect(api_client).to receive(:send_batch).at_least(:once)

      threads = 10.times.map do |i|
        Thread.new do
          score_client.create(name: "score_#{i}", value: i)
        end
      end

      threads.each(&:join)
      score_client.flush
    end
  end

  describe "event structure" do
    it "includes required fields" do
      expect(api_client).to receive(:send_batch) do |events|
        event = events.first
        expect(event).to have_key(:id)
        expect(event).to have_key(:type)
        expect(event).to have_key(:timestamp)
        expect(event).to have_key(:body)

        expect(event[:type]).to eq("score-create")
        expect(event[:id]).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
        expect(event[:timestamp]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/)

        body = event[:body]
        expect(body).to have_key(:id)
        expect(body[:id]).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
        expect(body[:id]).not_to eq(event[:id])
      end

      score_client.create(name: "quality", value: 0.85)
      score_client.flush
    end
  end
end
