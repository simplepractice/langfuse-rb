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

    it "replaces inherited queue and timer state in a forked child" do
      skip "fork is not available" unless Process.respond_to?(:fork)

      allow(api_client).to receive(:send_batch)
      score_client.create(name: "parent-score", value: 1)
      parent_queue = score_client.instance_variable_get(:@queue)
      parent_thread = score_client.instance_variable_get(:@flush_thread)
      child_pid, status, child_state = capture_forked_state do
        score_client.create(name: "child-score", value: 1)
        child_queue = score_client.instance_variable_get(:@queue)
        child_thread = score_client.instance_variable_get(:@flush_thread)
        score_client.flush
        {
          pid: Process.pid,
          queue_replaced: !child_queue.equal?(parent_queue),
          queue_empty_after_flush: child_queue.empty?,
          timer_alive: child_thread&.alive?
        }
      end

      expect(status).to be_success
      expect(child_state).to eq(
        pid: child_pid,
        queue_replaced: true,
        queue_empty_after_flush: true,
        timer_alive: true
      )
      expect(score_client.instance_variable_get(:@queue)).to equal(parent_queue)
      expect(score_client.instance_variable_get(:@queue).size).to eq(1)
      expect(score_client.instance_variable_get(:@flush_thread)).to equal(parent_thread)
      expect(parent_thread).to be_alive
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

      it "includes id when provided" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(id: "my-score")
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85, id: "my-score")
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

      it "includes session_id when provided" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(sessionId: "ghi789")
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85, session_id: "ghi789")
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

      it "accepts mixed identifier fields and serializes all of them" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(
                                                              traceId: "abc123",
                                                              sessionId: "ghi789",
                                                              observationId: "def456",
                                                              datasetRunId: "run-123"
                                                            )
                                                          )
                                                        ))

        score_client.create(
          name: "quality",
          value: 0.85,
          trace_id: "abc123",
          session_id: "ghi789",
          observation_id: "def456",
          dataset_run_id: "run-123"
        )
        score_client.flush
      end

      it "includes comment and metadata and environment when provided" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(
                                                              comment: "High quality",
                                                              metadata: { source: "manual" },
                                                              environment: "production"
                                                            )
                                                          )
                                                        ))

        score_client.create(
          name: "quality",
          value: 0.85,
          comment: "High quality",
          metadata: { source: "manual" },
          environment: "production"
        )
        score_client.flush
      end

      it "uses the configured environment when the score omits an override" do
        config.environment = "staging"
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(environment: "staging")
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85)
        score_client.flush
      end

      it "prefers the score environment over the configured environment" do
        config.environment = "staging"
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(environment: "production")
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85, environment: "production")
        score_client.flush
      end

      it "includes dataset_run_id when provided" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(datasetRunId: "run-123")
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85, dataset_run_id: "run-123")
        score_client.flush
      end

      it "includes config_id when provided" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(configId: "cfg-456")
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85, config_id: "cfg-456")
        score_client.flush
      end

      it "omits optional attributes when they and the configured environment are nil" do
        expect(api_client).to receive(:send_batch) do |events|
          body = events.first[:body]
          expect(body).not_to have_key(:environment)
          expect(body).not_to have_key(:datasetRunId)
          expect(body).not_to have_key(:configId)
        end

        score_client.create(name: "quality", value: 0.85)
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

    context "with text score" do
      it "emits dataType TEXT with the string value" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(
                                                              name: "reviewer_notes",
                                                              value: "Helpful but verbose",
                                                              dataType: "TEXT"
                                                            )
                                                          )
                                                        ))

        score_client.create(name: "reviewer_notes", value: "Helpful but verbose", data_type: :text)
        score_client.flush
      end

      it "accepts a 500-character value" do
        expect(api_client).to receive(:send_batch)

        score_client.create(name: "notes", value: "a" * 500, data_type: :text)
        score_client.flush
      end

      it "rejects an empty value" do
        expect do
          score_client.create(name: "notes", value: "", data_type: :text)
        end.to raise_error(ArgumentError, /Text value must contain 1 to 500 characters, got 0/)
      end

      it "rejects a value longer than 500 characters" do
        expect do
          score_client.create(name: "notes", value: "a" * 501, data_type: :text)
        end.to raise_error(ArgumentError, /Text value must contain 1 to 500 characters, got 501/)
      end

      it "rejects non-string values" do
        expect do
          score_client.create(name: "notes", value: 42, data_type: :text)
        end.to raise_error(ArgumentError, /Text value must be a String, got Integer/)
      end
    end

    context "with correction score" do
      it "emits dataType CORRECTION with the caller's name and string value" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(
                                                              name: "output",
                                                              value: "The corrected output",
                                                              dataType: "CORRECTION",
                                                              traceId: "trace-1",
                                                              observationId: "obs-1"
                                                            )
                                                          )
                                                        ))

        score_client.create(name: "output", value: "The corrected output",
                            trace_id: "trace-1", observation_id: "obs-1", data_type: :correction)
        score_client.flush
      end

      it "preserves an arbitrary caller-supplied name without rewriting it" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(body: hash_including(name: "custom-name"))
                                                        ))

        score_client.create(name: "custom-name", value: "corrected", trace_id: "trace-1", data_type: :correction)
        score_client.flush
      end

      it "does not enforce a length limit" do
        expect(api_client).to receive(:send_batch)

        score_client.create(name: "output", value: "a" * 10_000, trace_id: "trace-1", data_type: :correction)
        score_client.flush
      end

      it "rejects non-string values" do
        expect do
          score_client.create(name: "output", value: { text: "corrected" }, data_type: :correction)
        end.to raise_error(ArgumentError, /Correction value must be a String, got Hash/)
      end

      it "rejects subjects that Langfuse cannot attach a correction to" do
        invalid_subjects = [
          {},
          { observation_id: "obs-1" },
          { trace_id: "trace-1", session_id: "session-1" },
          { trace_id: "trace-1", dataset_run_id: "run-1" },
          { trace_id: "trace-1", config_id: "config-1" }
        ]

        invalid_subjects.each do |subject|
          expect do
            score_client.create(name: "output", value: "corrected", data_type: :correction, **subject)
          end.to raise_error(ArgumentError, /Correction scores require trace_id/)
        end
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

    context "with probabilistic trace sampling" do
      let(:original_tracer_provider) { OpenTelemetry.tracer_provider }

      before do
        config.sample_rate = 0.0
        OpenTelemetry.tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
          sampler: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON
        )
      end

      after do
        OpenTelemetry.tracer_provider = original_tracer_provider
      end

      it "drops trace-linked scores when Langfuse sampling rejects the trace id" do
        expect(api_client).not_to receive(:send_batch)

        score_client.create(
          name: "quality",
          value: 0.85,
          trace_id: "abcdef1234567890abcdef1234567890"
        )
        score_client.flush
      end

      it "keeps session-only scores regardless of sampler" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(sessionId: "session-123")
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85, session_id: "session-123")
        score_client.flush
      end

      it "keeps dataset-run-only scores regardless of sampler" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(datasetRunId: "run-123")
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85, dataset_run_id: "run-123")
        score_client.flush
      end

      it "keeps trace-linked scores for legacy non-hex trace ids" do
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(traceId: "legacy-trace-id")
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85, trace_id: "legacy-trace-id")
        score_client.flush
      end

      it "keeps uppercase hex trace ids as legacy ids to match langfuse-python" do
        uppercase_id = "ABCDEF1234567890ABCDEF1234567890"
        expect(api_client).to receive(:send_batch).with(array_including(
                                                          hash_including(
                                                            body: hash_including(traceId: uppercase_id)
                                                          )
                                                        ))

        score_client.create(name: "quality", value: 0.85, trace_id: uppercase_id)
        score_client.flush
      end
    end

    context "with per-client sample_rate isolation" do
      it "pins sample_rate at construction so later mutations don't diverge from tracing" do
        pinned_config = Langfuse::Config.new do |c|
          c.public_key = "pk_test"
          c.secret_key = "sk_test"
          c.base_url = "https://cloud.langfuse.com"
          c.sample_rate = 1.0
          c.flush_interval = 0
          c.logger = Logger.new(StringIO.new)
        end
        pinned_api_client = instance_double(Langfuse::ApiClient, send_batch: nil)
        pinned_client = described_class.new(api_client: pinned_api_client, config: pinned_config)

        # Mutate after construction — tracing would remain at 1.0 per the docs contract,
        # so scoring must stay at 1.0 too.
        pinned_config.sample_rate = 0.0

        hex_id = "abcdef1234567890abcdef1234567890"
        expect(pinned_api_client).to receive(:send_batch).with(
          array_including(hash_including(body: hash_including(traceId: hex_id)))
        )
        pinned_client.create(name: "quality", value: 1.0, trace_id: hex_id)
        pinned_client.flush
      end

      # Guards against a prior regression where ScoreClient read the sampler from
      # OtelSetup's singleton provider, so whichever client initialized tracing
      # first dictated sampling for every other client in the process.
      it "uses its own config's sample_rate, not another client's" do
        permissive_config = Langfuse::Config.new do |c|
          c.public_key = "pk_test"
          c.secret_key = "sk_test"
          c.base_url = "https://cloud.langfuse.com"
          c.sample_rate = 1.0
          c.flush_interval = 0
          c.logger = Logger.new(StringIO.new)
        end
        permissive_api_client = instance_double(Langfuse::ApiClient, send_batch: nil)
        described_class.new(api_client: permissive_api_client, config: permissive_config)

        strict_config = Langfuse::Config.new do |c|
          c.public_key = "pk_test"
          c.secret_key = "sk_test"
          c.base_url = "https://cloud.langfuse.com"
          c.sample_rate = 0.0
          c.flush_interval = 0
          c.logger = Logger.new(StringIO.new)
        end
        strict_api_client = instance_double(Langfuse::ApiClient, send_batch: nil)
        strict_client = described_class.new(api_client: strict_api_client, config: strict_config)

        expect(strict_api_client).not_to receive(:send_batch)
        strict_client.create(name: "quality", value: 1.0, trace_id: "abcdef1234567890abcdef1234567890")
        strict_client.flush
      end
    end
  end

  describe "#create!" do
    it "creates the score directly, returns its ID, and leaves the queue empty" do
      expect(api_client).to receive(:create_score).with(
        payload: hash_including(
          id: "score-123",
          name: "quality",
          value: 0.85,
          dataType: "NUMERIC",
          traceId: "abc123"
        )
      ).and_return("score-123")

      result = score_client.create!(
        id: "score-123",
        name: "quality",
        value: 0.85,
        trace_id: "abc123",
        data_type: :numeric
      )

      expect(result).to eq("score-123")
      expect(score_client.instance_variable_get(:@queue)).to be_empty
    end

    it "uses the configured environment when the score omits an override" do
      config.environment = "staging"
      expect(api_client).to receive(:create_score).with(
        payload: hash_including(environment: "staging")
      ).and_return("score-123")

      score_client.create!(id: "score-123", name: "quality", value: 0.85)
    end

    it "prefers the score environment over the configured environment" do
      config.environment = "staging"
      expect(api_client).to receive(:create_score).with(
        payload: hash_including(environment: "production")
      ).and_return("score-123")

      score_client.create!(id: "score-123", name: "quality", value: 0.85, environment: "production")
    end

    it "returns an automatically generated score ID" do
      allow(api_client).to receive(:create_score) { |payload:| payload.fetch(:id) }

      result = score_client.create!(name: "quality", value: 0.85, trace_id: "abc123")

      expect(result).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "bypasses sampling — delivers even when the configured sample_rate would drop it" do
      strict_config = Langfuse::Config.new do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
        c.base_url = "https://cloud.langfuse.com"
        c.sample_rate = 0.0
        c.flush_interval = 0
        c.logger = Logger.new(StringIO.new)
      end
      strict_api_client = instance_double(Langfuse::ApiClient)
      strict_client = described_class.new(api_client: strict_api_client, config: strict_config)

      expect(strict_api_client).to receive(:create_score)
      strict_client.create!(name: "quality", value: 1.0, trace_id: "abcdef1234567890abcdef1234567890")
    end

    it "raises the ApiClient error instead of swallowing it" do
      expect(api_client).to receive(:create_score).and_raise(Langfuse::ApiError, "API request failed (500): boom")

      expect do
        score_client.create!(name: "quality", value: 0.85)
      end.to raise_error(Langfuse::ApiError, "API request failed (500): boom")
    end

    it "raises ArgumentError for invalid input, same as #create" do
      expect do
        score_client.create!(name: nil, value: 0.85)
      end.to raise_error(ArgumentError, "name is required")
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

    it "drops sampled-out Langfuse spans without installing the global tracer provider" do
      original_tracer_provider = OpenTelemetry.tracer_provider
      config.sample_rate = 0.0
      Langfuse.reset!
      Langfuse.configure do |c|
        c.public_key = "pk_test"
        c.secret_key = "sk_test"
        c.base_url = "https://cloud.langfuse.com"
        c.sample_rate = 0.0
        c.logger = Logger.new(StringIO.new)
      end
      OpenTelemetry.tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
        sampler: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON
      )
      expect(api_client).not_to receive(:send_batch)

      Langfuse.observe("sampled-out") do
        score_client.score_active_trace(name: "overall_quality", value: 5)
      end
      score_client.flush
    ensure
      OpenTelemetry.tracer_provider = original_tracer_provider
      Langfuse.reset!
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

    it "splits requests before a multi-score payload exceeds the byte limit" do
      allow(api_client).to receive(:send_batch)
      3.times { |index| score_client.create(name: "score-#{index}", value: index) }
      pending_events = score_client.instance_variable_get(:@queue).snapshot
      single_event_bytes = JSON.generate(batch: [pending_events.first]).bytesize
      stub_const("Langfuse::ScoreClient::MAX_BATCH_PAYLOAD_BYTES", single_event_bytes)
      sent_batches = []
      allow(api_client).to receive(:send_batch) { |batch| sent_batches << batch }

      score_client.flush

      expect(sent_batches.length).to eq(3)
      expect(sent_batches.flatten.map { |event| event.dig(:body, :name) }).to eq(%w[score-0 score-1 score-2])
      expect(score_client.instance_variable_get(:@queue)).to be_empty
    end

    it "keeps a failed batch and later scores queued in their original order" do
      3.times { |index| score_client.create(name: "score-#{index}", value: index) }
      pending_queue = score_client.instance_variable_get(:@queue)
      single_event_bytes = JSON.generate(batch: [pending_queue.snapshot.first]).bytesize
      stub_const("Langfuse::ScoreClient::MAX_BATCH_PAYLOAD_BYTES", single_event_bytes)
      attempts = []
      allow(api_client).to receive(:send_batch) do |batch|
        attempts << batch.map { |event| event.dig(:body, :name) }
        raise Langfuse::ApiError, "unavailable" if attempts.length == 2
      end

      score_client.flush

      expect(attempts).to eq([%w[score-0], %w[score-1]])
      expect(pending_queue.snapshot.map { |event| event.dig(:body, :name) }).to eq(%w[score-1 score-2])

      retried_names = []
      allow(api_client).to receive(:send_batch) do |batch|
        retried_names.concat(batch.map { |event| event.dig(:body, :name) })
      end
      score_client.flush

      expect(retried_names).to eq(%w[score-1 score-2])
      expect(pending_queue).to be_empty
    end
  end

  describe "queue capacity" do
    before do
      config.score_queue_capacity = 1
      allow(api_client).to receive(:send_batch)
    end

    it "drops only the new score without blocking when the queue is full" do
      score_client.create(name: "accepted", value: 1)
      expect(config.logger).to receive(:error).with(
        "Langfuse score queue is full (capacity=1); dropping new asynchronous score"
      )

      enqueue_thread = Thread.new { score_client.create(name: "dropped", value: 2) }

      expect(enqueue_thread.join(1)).to equal(enqueue_thread)
      pending_names = score_client.instance_variable_get(:@queue).snapshot.map { |event| event.dig(:body, :name) }
      expect(pending_names).to eq(["accepted"])
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
