# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::OtelAttributes do
  describe "constants" do
    it "defines trace attribute constants" do
      expect(described_class::TRACE_NAME).to eq("langfuse.trace.name")
      expect(described_class::TRACE_USER_ID).to eq("user.id")
      expect(described_class::TRACE_SESSION_ID).to eq("session.id")
      expect(described_class::TRACE_INPUT).to eq("langfuse.trace.input")
      expect(described_class::TRACE_OUTPUT).to eq("langfuse.trace.output")
      expect(described_class::TRACE_METADATA).to eq("langfuse.trace.metadata")
      expect(described_class::TRACE_TAGS).to eq("langfuse.trace.tags")
      expect(described_class::TRACE_PUBLIC).to eq("langfuse.trace.public")
    end

    it "defines observation attribute constants" do
      expect(described_class::OBSERVATION_TYPE).to eq("langfuse.observation.type")
      expect(described_class::OBSERVATION_INPUT).to eq("langfuse.observation.input")
      expect(described_class::OBSERVATION_OUTPUT).to eq("langfuse.observation.output")
      expect(described_class::OBSERVATION_METADATA).to eq("langfuse.observation.metadata")
      expect(described_class::OBSERVATION_LEVEL).to eq("langfuse.observation.level")
      expect(described_class::OBSERVATION_STATUS_MESSAGE).to eq("langfuse.observation.status_message")
      expect(described_class::OBSERVATION_MODEL).to eq("langfuse.observation.model.name")
      expect(described_class::OBSERVATION_MODEL_PARAMETERS).to eq("langfuse.observation.model.parameters")
      expect(described_class::OBSERVATION_USAGE_DETAILS).to eq("langfuse.observation.usage_details")
      expect(described_class::OBSERVATION_COST_DETAILS).to eq("langfuse.observation.cost_details")
      expect(described_class::OBSERVATION_PROMPT_NAME).to eq("langfuse.observation.prompt.name")
      expect(described_class::OBSERVATION_PROMPT_VERSION).to eq("langfuse.observation.prompt.version")
      expect(described_class::OBSERVATION_COMPLETION_START_TIME).to eq("langfuse.observation.completion_start_time")
    end

    it "defines common attribute constants" do
      expect(described_class::VERSION).to eq("langfuse.version")
      expect(described_class::RELEASE).to eq("langfuse.release")
      expect(described_class::ENVIRONMENT).to eq("langfuse.environment")
    end
  end

  describe ".serialize" do
    it "returns nil for nil input" do
      expect(described_class.serialize(nil)).to be_nil
    end

    context "with default behavior (preserve_strings: false)" do
      it "always JSON-serializes strings" do
        expect(described_class.serialize("test string")).to eq('"test string"')
      end

      it "serializes arrays to JSON" do
        result = described_class.serialize([1, 2, 3])
        expect(result).to eq("[1,2,3]")
      end

      it "serializes complex nested objects" do
        obj = { user: { id: 123, name: "Test" }, tags: %w[a b c] }
        result = described_class.serialize(obj)
        expect(result).to eq('{"user":{"id":123,"name":"Test"},"tags":["a","b","c"]}')
      end

      it "handles serialization errors gracefully" do
        # Create an object that fails to serialize
        obj = Object.new
        def obj.to_json
          raise StandardError, "Cannot serialize"
        end

        result = described_class.serialize(obj)
        expect(result).to be_nil
      end
    end

    context "with preserve_strings: true" do
      it "returns strings as-is" do
        expect(described_class.serialize("test string", preserve_strings: true)).to eq("test string")
      end

      it "serializes arrays to JSON" do
        result = described_class.serialize([1, 2, 3], preserve_strings: true)
        expect(result).to eq("[1,2,3]")
      end

      it "serializes complex nested objects" do
        obj = { user: { id: 123, name: "Test" }, tags: %w[a b c] }
        result = described_class.serialize(obj, preserve_strings: true)
        expect(result).to eq('{"user":{"id":123,"name":"Test"},"tags":["a","b","c"]}')
      end

      it "handles serialization errors gracefully" do
        # Create an object that fails to serialize
        obj = Object.new
        def obj.to_json
          raise StandardError, "Cannot serialize"
        end

        result = described_class.serialize(obj, preserve_strings: true)
        expect(result).to be_nil
      end
    end
  end

  describe ".flatten_metadata" do
    it "returns empty hash for nil metadata" do
      result = described_class.flatten_metadata(nil, "langfuse.trace.metadata")
      expect(result).to eq({})
    end

    it "flattens simple hash metadata" do
      metadata = { source: "api", cache: "miss", key1: "value1", key2: "value2" }
      result = described_class.flatten_metadata(metadata, "langfuse.trace.metadata")

      expect(result).to eq({
                             "langfuse.trace.metadata.source" => "api",
                             "langfuse.trace.metadata.cache" => "miss",
                             "langfuse.trace.metadata.key1" => "value1",
                             "langfuse.trace.metadata.key2" => "value2"
                           })
    end

    it "flattens nested hash metadata" do
      metadata = { user: { id: 123, profile: { name: "Test" } } }
      result = described_class.flatten_metadata(metadata, "langfuse.trace.metadata")

      expect(result).to eq({
                             "langfuse.trace.metadata.user.id" => "123",
                             "langfuse.trace.metadata.user.profile.name" => "Test"
                           })
    end

    it "handles non-hash metadata by serializing under base prefix" do
      [
        [%w[tag1 tag2 tag3], "langfuse.trace.metadata", '["tag1","tag2","tag3"]'],
        ["simple string", "langfuse.observation.metadata", "simple string"],
        [123, "langfuse.trace.metadata", "123"]
      ].each do |metadata, prefix, expected_value|
        result = described_class.flatten_metadata(metadata, prefix)
        expect(result).to eq({ prefix => expected_value })
      end
    end

    it "skips nil values in metadata hash" do
      metadata = { key1: "value1", key2: nil, key3: "value3" }
      result = described_class.flatten_metadata(metadata, "langfuse.trace.metadata")

      expect(result).to eq({
                             "langfuse.trace.metadata.key1" => "value1",
                             "langfuse.trace.metadata.key3" => "value3"
                           })
    end
  end

  describe ".create_trace_attributes" do
    it "converts TraceAttributes object or hash to OTel format" do # rubocop:disable RSpec/ExampleLength
      # Test with TraceAttributes object
      attrs_obj = Langfuse::Types::TraceAttributes.new(
        name: "user-checkout-flow",
        user_id: "user-123",
        session_id: "session-456",
        version: "1.0.0",
        release: "v1.0.0",
        input: { query: "test" },
        output: { result: "success" },
        tags: %w[checkout payment],
        public: false,
        environment: "production"
      )

      result_obj = described_class.create_trace_attributes(attrs_obj)

      expect(result_obj).to include(
        "langfuse.trace.name" => "user-checkout-flow",
        "user.id" => "user-123",
        "session.id" => "session-456",
        "langfuse.version" => "1.0.0",
        "langfuse.release" => "v1.0.0",
        "langfuse.trace.input" => '{"query":"test"}',
        "langfuse.trace.output" => '{"result":"success"}',
        "langfuse.trace.tags" => '["checkout","payment"]',
        "langfuse.trace.public" => false,
        "langfuse.environment" => "production"
      )

      # Test with hash (including string keys)
      attrs_hash = {
        "name" => "test-trace",
        user_id: "user-456",
        "input" => { data: "test" },
        metadata: { source: "api" }
      }

      result_hash = described_class.create_trace_attributes(attrs_hash)

      expect(result_hash).to include(
        "langfuse.trace.name" => "test-trace",
        "user.id" => "user-456",
        "langfuse.trace.input" => '{"data":"test"}',
        "langfuse.trace.metadata.source" => "api"
      )
    end

    it "removes nil values" do
      attrs = Langfuse::Types::TraceAttributes.new(
        name: "test-trace",
        user_id: nil,
        session_id: nil,
        input: { data: "test" }
      )

      result = described_class.create_trace_attributes(attrs)

      expect(result).to include(
        "langfuse.trace.name" => "test-trace",
        "langfuse.trace.input" => '{"data":"test"}'
      )
      expect(result).not_to have_key("user.id")
      expect(result).not_to have_key("session.id")
    end

    it "handles empty or nil attributes" do
      # Test with empty attributes
      attrs = Langfuse::Types::TraceAttributes.new
      result_empty = described_class.create_trace_attributes(attrs)
      expect(result_empty).to eq({})

      # Test with nil input
      result_nil = described_class.create_trace_attributes(nil)
      expect(result_nil).to eq({})
    end
  end

  describe ".create_observation_attributes" do
    it "converts SpanAttributes object or hash to OTel format" do # rubocop:disable RSpec/ExampleLength
      # Test with SpanAttributes object
      attrs_obj = Langfuse::Types::SpanAttributes.new(
        input: { query: "test" },
        output: { result: "success" },
        level: "DEFAULT",
        status_message: "OK",
        version: "1.0.0",
        environment: "production",
        metadata: { source: "api" }
      )

      result_obj = described_class.create_observation_attributes("span", attrs_obj)

      expect(result_obj).to include(
        "langfuse.observation.type" => "span",
        "langfuse.observation.input" => '{"query":"test"}',
        "langfuse.observation.output" => '{"result":"success"}',
        "langfuse.observation.level" => "DEFAULT",
        "langfuse.observation.status_message" => "OK",
        "langfuse.version" => "1.0.0",
        "langfuse.environment" => "production",
        "langfuse.observation.metadata.source" => "api"
      )

      # Test with hash (including string keys)
      attrs_hash = {
        "input" => { data: "test" },
        output: { result: "success" },
        "level" => "ERROR",
        metadata: { source: "api" }
      }

      result_hash = described_class.create_observation_attributes("span", attrs_hash)

      expect(result_hash).to include(
        "langfuse.observation.type" => "span",
        "langfuse.observation.input" => '{"data":"test"}',
        "langfuse.observation.output" => '{"result":"success"}',
        "langfuse.observation.level" => "ERROR",
        "langfuse.observation.metadata.source" => "api"
      )
    end

    it "converts GenerationAttributes object to OTel format" do
      attrs = Langfuse::Types::GenerationAttributes.new(
        model: "gpt-4",
        input: { messages: [{ role: "user", content: "Hello" }] },
        output: { content: "Hi there!" },
        model_parameters: { temperature: 0.7, max_tokens: 100 },
        usage_details: { prompt_tokens: 100, completion_tokens: 50 },
        cost_details: { total_cost: 0.002 },
        level: "DEFAULT"
      )

      result = described_class.create_observation_attributes("generation", attrs)

      expect(result).to include(
        "langfuse.observation.type" => "generation",
        "langfuse.observation.model.name" => "gpt-4",
        "langfuse.observation.input" => '{"messages":[{"role":"user","content":"Hello"}]}',
        "langfuse.observation.output" => '{"content":"Hi there!"}',
        "langfuse.observation.model.parameters" => '{"temperature":0.7,"max_tokens":100}',
        "langfuse.observation.usage_details" => '{"prompt_tokens":100,"completion_tokens":50}',
        "langfuse.observation.cost_details" => '{"total_cost":0.002}',
        "langfuse.observation.level" => "DEFAULT"
      )
    end

    it "handles completion_start_time" do
      completion_time = Time.now
      attrs = Langfuse::Types::GenerationAttributes.new(
        model: "gpt-4",
        completion_start_time: completion_time
      )

      result = described_class.create_observation_attributes("generation", attrs)

      expect(result).to include(
        "langfuse.observation.completion_start_time" => completion_time.to_json
      )
    end

    it "handles prompt linking when is_fallback is false" do
      attrs = Langfuse::Types::GenerationAttributes.new(
        model: "gpt-4",
        prompt: { name: "greeting", version: 1, is_fallback: false }
      )

      result = described_class.create_observation_attributes("generation", attrs)

      expect(result).to include(
        "langfuse.observation.prompt.name" => "greeting",
        "langfuse.observation.prompt.version" => 1
      )
    end

    it "skips prompt linking when is_fallback is true" do
      attrs = Langfuse::Types::GenerationAttributes.new(
        model: "gpt-4",
        prompt: { name: "greeting", version: 1, is_fallback: true }
      )

      result = described_class.create_observation_attributes("generation", attrs)

      expect(result).not_to have_key("langfuse.observation.prompt.name")
      expect(result).not_to have_key("langfuse.observation.prompt.version")
    end

    it "handles prompt with string keys" do
      attrs = {
        model: "gpt-4",
        prompt: { "name" => "greeting", "version" => 2, "is_fallback" => false }
      }

      result = described_class.create_observation_attributes("generation", attrs)

      expect(result).to include(
        "langfuse.observation.prompt.name" => "greeting",
        "langfuse.observation.prompt.version" => 2
      )
    end

    it "handles nil prompt" do
      attrs = Langfuse::Types::GenerationAttributes.new(
        model: "gpt-4",
        prompt: nil
      )

      result = described_class.create_observation_attributes("generation", attrs)

      expect(result).not_to have_key("langfuse.observation.prompt.name")
      expect(result).not_to have_key("langfuse.observation.prompt.version")
    end

    it "handles empty or nil attributes" do
      # Test with empty attributes
      attrs = Langfuse::Types::SpanAttributes.new
      result_empty = described_class.create_observation_attributes("span", attrs)
      expect(result_empty).to eq({
                                   "langfuse.observation.type" => "span"
                                 })

      # Test with nil input
      result_nil = described_class.create_observation_attributes("span", nil)
      expect(result_nil).to eq({
                                 "langfuse.observation.type" => "span"
                               })
    end

    it "works with different observation types" do
      attrs = Langfuse::Types::SpanAttributes.new(input: { data: "test" })

      %w[span generation event embedding agent tool chain retriever evaluator guardrail].each do |type|
        result = described_class.create_observation_attributes(type, attrs)
        expect(result["langfuse.observation.type"]).to eq(type)
      end
    end
  end
end
