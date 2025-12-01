# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/sdk"

RSpec.describe Langfuse::BaseObservation do
  # Test subclass that passes type to super
  let(:test_subclass) do
    Class.new(Langfuse::BaseObservation) do
      def initialize(otel_span, otel_tracer, attributes: nil)
        super(otel_span, otel_tracer, attributes: attributes, type: "test_observation")
      end
    end
  end

  let(:tracer_provider) { OpenTelemetry::SDK::Trace::TracerProvider.new }
  let(:otel_tracer) { tracer_provider.tracer("test-tracer") }
  let(:otel_span) { otel_tracer.start_span("test-span") }
  let(:observation) { test_subclass.new(otel_span, otel_tracer) }

  describe "#initialize" do
    it "stores otel_span and otel_tracer" do
      expect(observation.otel_span).to eq(otel_span)
      expect(observation.otel_tracer).to eq(otel_tracer)
    end

    it "initializes without attributes" do
      obs = test_subclass.new(otel_span, otel_tracer)
      expect(obs.otel_span).to eq(otel_span)
      expect(obs.otel_tracer).to eq(otel_tracer)
    end

    it "sets initial attributes when provided" do
      attrs = { input: { query: "test" }, output: { result: "success" } }
      obs = test_subclass.new(otel_span, otel_tracer, attributes: attrs)
      span_data = obs.otel_span.to_span_data

      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "query" => "test" })
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "result" => "success" })
    end

    it "handles Types objects" do
      attrs = Langfuse::Types::SpanAttributes.new(
        input: { data: "test" },
        level: "DEFAULT"
      )
      obs = test_subclass.new(otel_span, otel_tracer, attributes: attrs)
      span_data = obs.otel_span.to_span_data

      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "data" => "test" })
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
    end
  end

  describe "#id" do
    it "returns hex-encoded span ID" do
      span_id = observation.id
      expect(span_id).to be_a(String)
      expect(span_id.length).to eq(16) # 8 bytes = 16 hex chars
      expect(span_id).to match(/\A[0-9a-f]{16}\z/)
    end

    it "matches the span context span_id" do
      expected_id = otel_span.context.span_id.unpack1("H*")
      expect(observation.id).to eq(expected_id)
    end
  end

  describe "#trace_id" do
    it "returns hex-encoded trace ID" do
      trace_id = observation.trace_id
      expect(trace_id).to be_a(String)
      expect(trace_id.length).to eq(32) # 16 bytes = 32 hex chars
      expect(trace_id).to match(/\A[0-9a-f]{32}\z/)
    end

    it "matches the span context trace_id" do
      expected_id = otel_span.context.trace_id.unpack1("H*")
      expect(observation.trace_id).to eq(expected_id)
    end
  end

  describe "#type" do
    it "returns the type set during initialization" do
      expect(observation.type).to eq("test_observation")
    end

    it "raises ArgumentError if type is not provided" do
      abstract_class = Class.new(described_class)
      expect { abstract_class.new(otel_span, otel_tracer) }.to raise_error(ArgumentError, /type must be provided/)
    end

    it "returns the type passed to initialize" do
      abstract_class = Class.new(described_class)
      obs = abstract_class.new(otel_span, otel_tracer, type: "custom_type")

      expect(obs.type).to eq("custom_type")
    end
  end

  describe "#end" do
    it "ends the observation without end_time" do
      expect(otel_span).to receive(:finish).with(end_timestamp: nil)
      observation.end
    end

    it "ends the observation with Time end_time" do
      end_time = Time.now
      expect(otel_span).to receive(:finish).with(end_timestamp: end_time)
      observation.end(end_time: end_time)
    end

    it "ends the observation with Integer timestamp" do
      timestamp = 1_000_000_000_000_000_000 # nanoseconds
      expect(otel_span).to receive(:finish).with(end_timestamp: timestamp)
      observation.end(end_time: timestamp)
    end
  end

  describe "#update_trace" do
    it "updates trace-level attributes" do
      observation.update_trace(
        user_id: "user-123",
        session_id: "session-456",
        tags: %w[production api-v2]
      )

      span_data = otel_span.to_span_data
      expect(span_data.attributes["user.id"]).to eq("user-123")
      expect(span_data.attributes["session.id"]).to eq("session-456")
      tags = JSON.parse(span_data.attributes["langfuse.trace.tags"])
      expect(tags).to eq(%w[production api-v2])
    end

    it "supports method chaining" do
      result = observation.update_trace(user_id: "user-123")
      expect(result).to eq(observation)
    end

    it "handles Types::TraceAttributes objects" do
      attrs = Langfuse::Types::TraceAttributes.new(
        user_id: "user-789",
        metadata: { version: "1.0.0" }
      )
      observation.update_trace(attrs)

      span_data = otel_span.to_span_data
      expect(span_data.attributes["user.id"]).to eq("user-789")
      expect(span_data.attributes["langfuse.trace.metadata.version"]).to eq("1.0.0")
    end
  end

  describe "#start_observation" do
    context "with block (auto-ends)" do
      it "creates a child observation and auto-ends" do
        result = observation.start_observation("child-operation", { input: { step: "processing" } }) do |child|
          expect(child).to be_a(described_class)
          expect(child.type).to eq("span") # Default type
          "block_result"
        end

        expect(result).to eq("block_result")
      end

      it "creates a generation child observation" do
        result = observation.start_observation("llm-call", {
                                                 input: [{ role: "user", content: "Hello" }],
                                                 model: "gpt-4"
                                               }, as_type: :generation) do |child|
          expect(child).to be_a(Langfuse::Generation)
          expect(child.type).to eq("generation")
          "gen_result"
        end

        expect(result).to eq("gen_result")
      end

      it "sets attributes on child observation" do
        observation.start_observation("child", { input: { data: "test" }, level: "ERROR" }) do |child|
          span_data = child.otel_span.to_span_data
          expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "data" => "test" })
          expect(span_data.attributes["langfuse.observation.level"]).to eq("ERROR")
        end
      end
    end

    context "without block (stateful API)" do
      it "creates a child observation and returns it" do
        child = observation.start_observation("child-operation", { input: { step: "processing" } })

        expect(child).to be_a(Langfuse::Span)
        expect(child.type).to eq("span")
      end

      it "creates a generation child observation" do
        child = observation.start_observation("llm-call", {
                                                input: [{ role: "user", content: "Hello" }],
                                                model: "gpt-4"
                                              }, as_type: :generation)

        expect(child).to be_a(Langfuse::Generation)
        expect(child.type).to eq("generation")
      end

      it "requires manual end" do
        child = observation.start_observation("child-operation")
        expect(child.otel_span).to receive(:finish)
        child.end
      end

      it "sets attributes on child observation" do
        child = observation.start_observation("child", { input: { data: "test" }, level: "WARNING" })
        span_data = child.otel_span.to_span_data

        expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "data" => "test" })
        expect(span_data.attributes["langfuse.observation.level"]).to eq("WARNING")
      end

      it "supports different observation types" do
        # NOTE: Only "generation" gets a specialized wrapper (Generation)
        # All other types (span, event, tool, agent) use Span wrapper
        # but the type attribute should still be set correctly on the span
        child = observation.start_observation("test", {}, as_type: :generation)
        span_data = child.otel_span.to_span_data
        expect(span_data.attributes["langfuse.observation.type"]).to eq("generation")

        # For other types, they use Span wrapper which overrides type to "span"
        # The initial type set on the span gets overwritten by Span#type
        # This is expected behavior - Span wrapper always represents "span" type
        child = observation.start_observation("test", {}, as_type: :span)
        span_data = child.otel_span.to_span_data
        expect(span_data.attributes["langfuse.observation.type"]).to eq("span")
      end
    end
  end

  describe "#input=" do
    it "sets input attribute" do
      observation.input = { query: "SELECT * FROM users" }
      span_data = otel_span.to_span_data

      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "query" => "SELECT * FROM users" })
    end

    it "handles complex nested objects" do
      observation.input = { user: { id: 123, name: "Test" }, tags: %w[a b c] }
      span_data = otel_span.to_span_data

      parsed = JSON.parse(span_data.attributes["langfuse.observation.input"])
      expect(parsed["user"]["id"]).to eq(123)
      expect(parsed["user"]["name"]).to eq("Test")
      expect(parsed["tags"]).to eq(%w[a b c])
    end
  end

  describe "#output=" do
    it "sets output attribute" do
      observation.output = { result: "success", count: 42 }
      span_data = otel_span.to_span_data

      parsed_output = JSON.parse(span_data.attributes["langfuse.observation.output"])
      expect(parsed_output).to eq({ "result" => "success", "count" => 42 })
    end

    it "handles arrays" do
      observation.output = [1, 2, 3, 4, 5]
      span_data = otel_span.to_span_data

      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq([1, 2, 3, 4, 5])
    end
  end

  describe "#metadata=" do
    it "sets metadata as individual attributes" do
      observation.metadata = { source: "database", cache: "miss" }
      span_data = otel_span.to_span_data

      expect(span_data.attributes["langfuse.observation.metadata.source"]).to eq("database")
      expect(span_data.attributes["langfuse.observation.metadata.cache"]).to eq("miss")
    end

    it "handles nested metadata" do
      observation.metadata = { user: { id: 123, profile: { name: "Test" } } }
      span_data = otel_span.to_span_data

      expect(span_data.attributes["langfuse.observation.metadata.user.id"]).to eq("123")
      expect(span_data.attributes["langfuse.observation.metadata.user.profile.name"]).to eq("Test")
    end
  end

  describe "#level=" do
    it "sets level attribute" do
      observation.level = "WARNING"
      span_data = otel_span.to_span_data

      expect(span_data.attributes["langfuse.observation.level"]).to eq("WARNING")
    end

    it "handles different level values" do
      %w[DEBUG DEFAULT WARNING ERROR].each do |level|
        obs = test_subclass.new(otel_tracer.start_span("test"), otel_tracer)
        obs.level = level
        span_data = obs.otel_span.to_span_data
        expect(span_data.attributes["langfuse.observation.level"]).to eq(level)
      end
    end
  end

  describe "#event" do
    it "adds an event with name only" do
      observation.event(name: "cache-hit")
      events = otel_span.to_span_data.events

      expect(events.length).to eq(1)
      expect(events.first.name).to eq("cache-hit")
    end

    it "adds an event with name and input" do
      observation.event(name: "cache-miss", input: { key: "user:123" })
      events = otel_span.to_span_data.events

      expect(events.length).to eq(1)
      expect(events.first.name).to eq("cache-miss")
      expect(JSON.parse(events.first.attributes["langfuse.observation.input"])).to eq({ "key" => "user:123" })
    end

    it "adds an event with level" do
      observation.event(name: "error-occurred", level: "error")
      events = otel_span.to_span_data.events

      expect(events.length).to eq(1)
      expect(events.first.attributes["langfuse.observation.level"]).to eq("error")
    end

    it "defaults level to 'default'" do
      observation.event(name: "test-event")
      events = otel_span.to_span_data.events

      expect(events.first.attributes["langfuse.observation.level"]).to eq("default")
    end

    it "handles nil input" do
      observation.event(name: "simple-event", input: nil)
      events = otel_span.to_span_data.events

      expect(events.length).to eq(1)
      expect(events.first.attributes).not_to have_key("langfuse.observation.input")
    end
  end

  describe "#current_span" do
    it "returns the underlying OTel span" do
      expect(observation.current_span).to eq(otel_span)
    end
  end

  describe "#update_observation_attributes" do
    it "is protected and called by convenience setters" do
      # This is tested indirectly through the convenience setters
      # We can't directly test protected methods, but we verify they work
      observation.input = { test: "data" }
      span_data = otel_span.to_span_data

      expect(span_data.attributes).to have_key("langfuse.observation.input")
    end
  end

  describe "#normalize_prompt" do
    it "is protected and extracts name/version from prompt objects" do
      # Test indirectly through start_observation with a prompt
      prompt_obj = double(name: "greeting", version: 2)
      child = observation.start_observation("test", { prompt: prompt_obj }, as_type: :generation)
      span_data = child.otel_span.to_span_data

      expect(span_data.attributes["langfuse.observation.prompt.name"]).to eq("greeting")
      expect(span_data.attributes["langfuse.observation.prompt.version"]).to eq(2)
    end

    it "handles hash prompts" do
      prompt_hash = { name: "greeting", version: 3 }
      child = observation.start_observation("test", { prompt: prompt_hash }, as_type: :generation)
      span_data = child.otel_span.to_span_data

      expect(span_data.attributes["langfuse.observation.prompt.name"]).to eq("greeting")
      expect(span_data.attributes["langfuse.observation.prompt.version"]).to eq(3)
    end

    it "handles non-prompt objects" do
      # Objects without name/version methods should pass through
      regular_obj = { some: "data" }
      child = observation.start_observation("test", { prompt: regular_obj }, as_type: :generation)
      span_data = child.otel_span.to_span_data

      # Should not have prompt attributes
      expect(span_data.attributes).not_to have_key("langfuse.observation.prompt.name")
    end

    it "normalizes prompt objects that respond to name and version" do
      # Create an object that responds to name and version methods
      prompt_obj = Class.new do
        def name
          "test_prompt"
        end

        def version
          42
        end
      end.new

      child = observation.start_observation("test", { prompt: prompt_obj }, as_type: :generation)
      span_data = child.otel_span.to_span_data

      expect(span_data.attributes["langfuse.observation.prompt.name"]).to eq("test_prompt")
      expect(span_data.attributes["langfuse.observation.prompt.version"]).to eq(42)
    end
  end

  describe "Generation setters" do
    before do
      Langfuse.configure do |config|
        config.public_key = "pk_test"
        config.secret_key = "sk_test"
        config.base_url = "https://cloud.langfuse.com"
      end
    end

    let(:generation) { Langfuse.start_observation("generation", {}, as_type: :generation) }

    it "sets usage via assignment" do
      generation.usage = { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 }
      span_data = generation.otel_span.to_span_data
      usage_attr_value = span_data.attributes["langfuse.observation.usage"]
      expect(usage_attr_value).not_to be_nil
      usage_attr = JSON.parse(usage_attr_value)
      expect(usage_attr["promptTokens"]).to eq(100)
      expect(usage_attr["completionTokens"]).to eq(50)
      expect(usage_attr["totalTokens"]).to eq(150)
    end

    it "sets model via assignment" do
      generation.model = "gpt-4"
      span_data = generation.otel_span.to_span_data
      expect(span_data.attributes["langfuse.observation.model"]).to eq("gpt-4")
    end

    it "sets model_parameters via assignment" do
      generation.model_parameters = { temperature: 0.7, max_tokens: 100 }
      span_data = generation.otel_span.to_span_data
      params_attr_value = span_data.attributes["langfuse.observation.modelParameters"]
      expect(params_attr_value).not_to be_nil
      params_attr = JSON.parse(params_attr_value)
      expect(params_attr["temperature"]).to eq(0.7)
      expect(params_attr["maxTokens"]).to eq(100)
    end

    it "returns self from update" do
      result = generation.update({ output: "test" })
      expect(result).to eq(generation)
    end
  end

  describe "#start_observation type handling" do
    it "creates Generation wrapper for generation type" do
      child = observation.start_observation("test", {}, as_type: :generation)
      expect(child).to be_a(Langfuse::Generation)
    end

    it "creates Span wrapper for span type" do
      child = observation.start_observation("test", {}, as_type: :span)
      expect(child).to be_a(Langfuse::Span)
    end

    it "creates Event wrapper for event type" do
      child = observation.start_observation("test", {}, as_type: :event)
      expect(child).to be_a(Langfuse::Event)
    end

    it "creates specific wrapper classes for known types" do
      type_map = {
        tool: Langfuse::Tool,
        agent: Langfuse::Agent,
        chain: Langfuse::Chain,
        retriever: Langfuse::Retriever,
        evaluator: Langfuse::Evaluator,
        guardrail: Langfuse::Guardrail,
        embedding: Langfuse::Embedding
      }

      type_map.each do |type, expected_class|
        child = observation.start_observation("test", {}, as_type: type)
        expect(child).to be_a(expected_class)
      end
    end

    it "creates Span wrapper for unrecognized types" do
      child = observation.start_observation("test", {}, as_type: :unknown_type)
      expect(child).to be_a(Langfuse::Span)
    end
  end

  describe "hierarchical structure" do
    it "creates nested observations" do
      parent_span = otel_tracer.start_span("parent")
      parent_obs = Langfuse::Span.new(parent_span, otel_tracer)

      parent_obs.start_observation("level-1") do |span1|
        span1.start_observation("level-2") do |span2|
          span2.start_observation("level-3") do |span3|
            expect(span3).to be_a(described_class)
            expect(span3.trace_id).to eq(parent_obs.trace_id)
          end
        end
      end
    end

    it "shares trace_id across nested observations" do
      parent_span = otel_tracer.start_span("parent")
      parent_obs = Langfuse::Span.new(parent_span, otel_tracer)
      trace_id = parent_obs.trace_id

      child = parent_obs.start_observation("child")
      grandchild = child.start_observation("grandchild")
      expect(grandchild.trace_id).to eq(trace_id)
      grandchild.end
      child.end
    end
  end

  describe "integration with real OpenTelemetry spans" do
    it "works with actual span lifecycle" do
      parent_span = otel_tracer.start_span("parent")
      parent_obs = Langfuse::Span.new(parent_span, otel_tracer)

      child = parent_obs.start_observation("child-operation", { input: { data: "test" } })
      child.output = { result: "success" }
      child.metadata = { source: "api" }
      child.level = "DEFAULT"
      span_data = child.otel_span.to_span_data
      child.end

      expect(span_data.attributes["langfuse.observation.type"]).to eq("span")
      expect(JSON.parse(span_data.attributes["langfuse.observation.input"])).to eq({ "data" => "test" })
      expect(JSON.parse(span_data.attributes["langfuse.observation.output"])).to eq({ "result" => "success" })
      expect(span_data.attributes["langfuse.observation.metadata.source"]).to eq("api")
      expect(span_data.attributes["langfuse.observation.level"]).to eq("DEFAULT")
    end
  end

  describe "#trace_url" do
    before do
      Langfuse.configure do |config|
        config.public_key = "pk_test_123"
        config.secret_key = "sk_test_456"
        config.base_url = "https://cloud.langfuse.com"
      end
    end

    after do
      Langfuse.reset!
    end

    it "generates trace URL using client" do
      trace_id = observation.trace_id
      url = observation.trace_url

      expect(url).to eq("https://cloud.langfuse.com/traces/#{trace_id}")
    end

    it "uses configured base_url" do
      Langfuse.configure do |config|
        config.public_key = "pk_test_123"
        config.secret_key = "sk_test_456"
        config.base_url = "https://custom.langfuse.com"
      end

      trace_id = observation.trace_id
      url = observation.trace_url

      expect(url).to eq("https://custom.langfuse.com/traces/#{trace_id}")
    end

    it "calls client.trace_url with correct trace_id" do
      mock_client = instance_double(Langfuse::Client)
      allow(Langfuse).to receive(:client).and_return(mock_client)
      trace_id = observation.trace_id

      expect(mock_client).to receive(:trace_url).with(trace_id).and_return("https://example.com/traces/#{trace_id}")

      observation.trace_url
    end
  end
end
