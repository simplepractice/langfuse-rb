# frozen_string_literal: true

RSpec.describe Langfuse::Types do
  describe "OBSERVATION_TYPES" do
    it "contains all 10 observation types" do
      expect(described_class::OBSERVATION_TYPES).to be_a(Array)
      expect(described_class::OBSERVATION_TYPES.length).to eq(10)
      expect(described_class::OBSERVATION_TYPES).to contain_exactly(
        "span", "generation", "event", "embedding",
        "agent", "tool", "chain", "retriever",
        "evaluator", "guardrail"
      )
    end

    it "is frozen" do
      expect(described_class::OBSERVATION_TYPES).to be_frozen
    end
  end

  describe "LEVELS" do
    it "contains all 4 severity levels" do
      expect(described_class::LEVELS).to be_a(Array)
      expect(described_class::LEVELS.length).to eq(4)
      expect(described_class::LEVELS).to contain_exactly(
        "DEBUG", "DEFAULT", "WARNING", "ERROR"
      )
    end

    it "is frozen" do
      expect(described_class::LEVELS).to be_frozen
    end
  end

  describe Langfuse::Types::SpanAttributes do
    describe "#initialize" do
      it "accepts keyword arguments" do
        attrs = described_class.new(
          input: { query: "test" },
          output: { result: "success" },
          metadata: { source: "api" },
          level: "DEFAULT",
          status_message: "OK",
          version: "1.0.0",
          environment: "production"
        )

        expect(attrs.input).to eq({ query: "test" })
        expect(attrs.output).to eq({ result: "success" })
        expect(attrs.metadata).to eq({ source: "api" })
        expect(attrs.level).to eq("DEFAULT")
        expect(attrs.status_message).to eq("OK")
        expect(attrs.version).to eq("1.0.0")
        expect(attrs.environment).to eq("production")
      end

      it "accepts nil values" do
        attrs = described_class.new
        expect(attrs.input).to be_nil
        expect(attrs.output).to be_nil
        expect(attrs.metadata).to be_nil
        expect(attrs.level).to be_nil
        expect(attrs.status_message).to be_nil
        expect(attrs.version).to be_nil
        expect(attrs.environment).to be_nil
      end

      it "accepts partial arguments" do
        attrs = described_class.new(input: "test", level: "ERROR")
        expect(attrs.input).to eq("test")
        expect(attrs.level).to eq("ERROR")
        expect(attrs.output).to be_nil
      end
    end

    describe "#to_h" do
      it "returns hash representation excluding nil values" do
        attrs = described_class.new(input: "test", level: "DEFAULT")
        result = attrs.to_h

        expect(result).to be_a(Hash)
        expect(result[:input]).to eq("test")
        expect(result[:level]).to eq("DEFAULT")
        expect(result).not_to have_key(:output)
        expect(result).not_to have_key(:metadata)
        expect(result).not_to have_key(:status_message)
        expect(result).not_to have_key(:version)
        expect(result).not_to have_key(:environment)
      end

      it "includes all set values" do
        attrs = described_class.new(
          input: { query: "test" },
          output: { result: "success" },
          metadata: { key: "value" },
          level: "WARNING",
          status_message: "Warning message",
          version: "2.0.0",
          environment: "staging"
        )

        result = attrs.to_h
        expect(result[:input]).to eq({ query: "test" })
        expect(result[:output]).to eq({ result: "success" })
        expect(result[:metadata]).to eq({ key: "value" })
        expect(result[:level]).to eq("WARNING")
        expect(result[:status_message]).to eq("Warning message")
        expect(result[:version]).to eq("2.0.0")
        expect(result[:environment]).to eq("staging")
      end

      it "returns empty hash when all values are nil" do
        attrs = described_class.new
        expect(attrs.to_h).to eq({})
      end
    end
  end

  describe Langfuse::Types::GenerationAttributes do
    describe "inheritance" do
      it "extends SpanAttributes" do
        expect(described_class.superclass).to eq(Langfuse::Types::SpanAttributes)
      end

      it "inherits base attributes from SpanAttributes" do
        attrs = described_class.new(
          input: "test",
          level: "DEFAULT",
          model: "gpt-4"
        )

        expect(attrs.input).to eq("test")
        expect(attrs.level).to eq("DEFAULT")
        expect(attrs.model).to eq("gpt-4")
      end
    end

    describe "#initialize" do
      it "accepts generation-specific attributes" do
        completion_time = Time.now
        attrs = described_class.new(
          completion_start_time: completion_time,
          model: "gpt-4",
          model_parameters: { temperature: 0.7, max_tokens: 100 },
          usage_details: { prompt_tokens: 100, completion_tokens: 50 },
          cost_details: { total_cost: 0.002 },
          prompt: { name: "greeting", version: 1, is_fallback: false }
        )

        expect(attrs.completion_start_time).to eq(completion_time)
        expect(attrs.model).to eq("gpt-4")
        expect(attrs.model_parameters).to eq({ temperature: 0.7, max_tokens: 100 })
        expect(attrs.usage_details).to eq({ prompt_tokens: 100, completion_tokens: 50 })
        expect(attrs.cost_details).to eq({ total_cost: 0.002 })
        expect(attrs.prompt).to eq({ name: "greeting", version: 1, is_fallback: false })
      end

      it "accepts both span and generation attributes" do
        attrs = described_class.new(
          input: "test",
          level: "DEFAULT",
          model: "claude-3",
          usage_details: { tokens: 200 }
        )

        expect(attrs.input).to eq("test")
        expect(attrs.level).to eq("DEFAULT")
        expect(attrs.model).to eq("claude-3")
        expect(attrs.usage_details).to eq({ tokens: 200 })
      end
    end

    describe "#to_h" do
      it "includes all span and generation attributes" do
        attrs = described_class.new(
          input: "test",
          level: "DEFAULT",
          model: "gpt-4",
          model_parameters: { temperature: 0.7 },
          usage_details: { tokens: 100 },
          prompt: { name: "test", version: 1, is_fallback: false }
        )

        result = attrs.to_h
        expect(result[:input]).to eq("test")
        expect(result[:level]).to eq("DEFAULT")
        expect(result[:model]).to eq("gpt-4")
        expect(result[:model_parameters]).to eq({ temperature: 0.7 })
        expect(result[:usage_details]).to eq({ tokens: 100 })
        expect(result[:prompt]).to eq({ name: "test", version: 1, is_fallback: false })
      end

      it "excludes nil generation attributes" do
        attrs = described_class.new(input: "test", model: "gpt-4")
        result = attrs.to_h

        expect(result[:input]).to eq("test")
        expect(result[:model]).to eq("gpt-4")
        expect(result).not_to have_key(:completion_start_time)
        expect(result).not_to have_key(:model_parameters)
        expect(result).not_to have_key(:usage_details)
        expect(result).not_to have_key(:cost_details)
        expect(result).not_to have_key(:prompt)
      end

      it "handles prompt hash structure correctly" do
        attrs = described_class.new(
          prompt: { name: "greeting", version: 2, is_fallback: true }
        )

        result = attrs.to_h
        expect(result[:prompt]).to eq({ name: "greeting", version: 2, is_fallback: true })
      end
    end
  end

  describe Langfuse::Types::EmbeddingAttributes do
    describe "inheritance" do
      it "extends GenerationAttributes" do
        expect(described_class.superclass).to eq(Langfuse::Types::GenerationAttributes)
      end

      it "inherits all GenerationAttributes methods" do
        attrs = described_class.new(
          input: "test",
          model: "text-embedding-ada-002",
          usage_details: { tokens: 50 }
        )

        expect(attrs.input).to eq("test")
        expect(attrs.model).to eq("text-embedding-ada-002")
        expect(attrs.usage_details).to eq({ tokens: 50 })
      end
    end

    describe "#to_h" do
      it "works correctly" do
        attrs = described_class.new(model: "embedding-model")
        result = attrs.to_h
        expect(result[:model]).to eq("embedding-model")
      end
    end
  end

  describe Langfuse::Types::TraceAttributes do
    describe "#initialize" do
      it "accepts keyword arguments" do
        attrs = described_class.new(
          name: "user-request",
          user_id: "user-123",
          session_id: "session-456",
          version: "1.0.0",
          release: "v1.0.0",
          input: { query: "test" },
          output: { result: "success" },
          metadata: { source: "api" },
          tags: %w[api v1],
          public: false,
          environment: "production"
        )

        expect(attrs.name).to eq("user-request")
        expect(attrs.user_id).to eq("user-123")
        expect(attrs.session_id).to eq("session-456")
        expect(attrs.version).to eq("1.0.0")
        expect(attrs.release).to eq("v1.0.0")
        expect(attrs.input).to eq({ query: "test" })
        expect(attrs.output).to eq({ result: "success" })
        expect(attrs.metadata).to eq({ source: "api" })
        expect(attrs.tags).to eq(%w[api v1])
        expect(attrs.public).to be(false)
        expect(attrs.environment).to eq("production")
      end

      it "accepts nil values" do
        attrs = described_class.new
        expect(attrs.name).to be_nil
        expect(attrs.user_id).to be_nil
        expect(attrs.tags).to be_nil
        expect(attrs.public).to be_nil
      end
    end

    describe "#to_h" do
      it "returns hash representation excluding nil values" do
        attrs = described_class.new(name: "test", user_id: "user-123")
        result = attrs.to_h

        expect(result).to be_a(Hash)
        expect(result[:name]).to eq("test")
        expect(result[:user_id]).to eq("user-123")
        expect(result).not_to have_key(:session_id)
        expect(result).not_to have_key(:tags)
        expect(result).not_to have_key(:public)
      end

      it "includes all set values" do
        attrs = described_class.new(
          name: "trace-name",
          user_id: "user-123",
          session_id: "session-456",
          tags: %w[tag1 tag2],
          public: true,
          input: { data: "test" }
        )

        result = attrs.to_h
        expect(result[:name]).to eq("trace-name")
        expect(result[:user_id]).to eq("user-123")
        expect(result[:session_id]).to eq("session-456")
        expect(result[:tags]).to eq(%w[tag1 tag2])
        expect(result[:public]).to be(true)
        expect(result[:input]).to eq({ data: "test" })
      end

      it "handles tags as array" do
        attrs = described_class.new(tags: %w[api v1 production])
        result = attrs.to_h
        expect(result[:tags]).to eq(%w[api v1 production])
      end

      it "handles public as boolean" do
        attrs = described_class.new(public: true)
        result = attrs.to_h
        expect(result[:public]).to be(true)

        attrs.public = false
        result = attrs.to_h
        expect(result[:public]).to be(false)
      end

      it "returns empty hash when all values are nil" do
        attrs = described_class.new
        expect(attrs.to_h).to eq({})
      end
    end
  end

  describe "alias classes" do
    it "EventAttributes equals SpanAttributes" do
      expect(Langfuse::Types::EventAttributes).to eq(Langfuse::Types::SpanAttributes)
    end

    it "AgentAttributes equals SpanAttributes" do
      expect(Langfuse::Types::AgentAttributes).to eq(Langfuse::Types::SpanAttributes)
    end

    it "ToolAttributes equals SpanAttributes" do
      expect(Langfuse::Types::ToolAttributes).to eq(Langfuse::Types::SpanAttributes)
    end

    it "ChainAttributes equals SpanAttributes" do
      expect(Langfuse::Types::ChainAttributes).to eq(Langfuse::Types::SpanAttributes)
    end

    it "RetrieverAttributes equals SpanAttributes" do
      expect(Langfuse::Types::RetrieverAttributes).to eq(Langfuse::Types::SpanAttributes)
    end

    it "EvaluatorAttributes equals SpanAttributes" do
      expect(Langfuse::Types::EvaluatorAttributes).to eq(Langfuse::Types::SpanAttributes)
    end

    it "GuardrailAttributes equals SpanAttributes" do
      expect(Langfuse::Types::GuardrailAttributes).to eq(Langfuse::Types::SpanAttributes)
    end

    it "alias classes can be instantiated" do
      event_attrs = Langfuse::Types::EventAttributes.new(input: "test")
      expect(event_attrs).to be_a(Langfuse::Types::SpanAttributes)
      expect(event_attrs.input).to eq("test")

      agent_attrs = Langfuse::Types::AgentAttributes.new(level: "ERROR")
      expect(agent_attrs).to be_a(Langfuse::Types::SpanAttributes)
      expect(agent_attrs.level).to eq("ERROR")
    end
  end
end
