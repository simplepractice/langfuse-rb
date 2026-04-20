# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Langfuse span filters" do
  def make_span(scope_name: nil, attributes: nil)
    scope = scope_name ? Struct.new(:name).new(scope_name) : nil
    Struct.new(:instrumentation_scope, :attributes).new(scope, attributes)
  end

  describe ".langfuse_span?" do
    it "matches Langfuse spans" do
      expect(Langfuse.langfuse_span?(make_span(scope_name: Langfuse::LANGFUSE_TRACER_NAME))).to be true
    end

    it "rejects other scopes" do
      expect(Langfuse.langfuse_span?(make_span(scope_name: "other-lib"))).to be false
    end

    it "keeps the compatibility alias" do
      expect(Langfuse.is_langfuse_span(make_span(scope_name: Langfuse::LANGFUSE_TRACER_NAME))).to be true
    end
  end

  describe ".genai_span?" do
    it "matches gen_ai attributes" do
      expect(Langfuse.genai_span?(make_span(attributes: { "gen_ai.system" => "openai" }))).to be true
    end

    it "rejects non gen_ai attributes" do
      expect(Langfuse.genai_span?(make_span(attributes: { "http.method" => "GET" }))).to be false
    end

    it "keeps the compatibility alias" do
      expect(Langfuse.is_genai_span(make_span(attributes: { "gen_ai.system" => "openai" }))).to be true
    end
  end

  describe ".known_llm_instrumentor?" do
    it "matches exact prefixes" do
      expect(Langfuse.known_llm_instrumentor?(make_span(scope_name: "ai"))).to be true
    end

    it "matches descendant scopes" do
      expect(Langfuse.known_llm_instrumentor?(make_span(scope_name: "langsmith.client"))).to be true
    end

    it "rejects unrelated scopes" do
      expect(Langfuse.known_llm_instrumentor?(make_span(scope_name: "dalli"))).to be false
    end

    it "keeps the compatibility alias" do
      expect(Langfuse.is_known_llm_instrumentor(make_span(scope_name: "langsmith.client"))).to be true
    end
  end

  describe ".default_export_span?" do
    it "keeps Langfuse spans" do
      expect(Langfuse.default_export_span?(make_span(scope_name: Langfuse::LANGFUSE_TRACER_NAME))).to be true
    end

    it "keeps gen_ai spans" do
      expect(Langfuse.default_export_span?(make_span(attributes: { "gen_ai.request.model" => "gpt-4" }))).to be true
    end

    it "keeps known LLM instrumentation scopes" do
      expect(Langfuse.default_export_span?(make_span(scope_name: "openinference.instrumentation"))).to be true
    end

    it "drops unrelated spans" do
      expect(Langfuse.default_export_span?(make_span(scope_name: "dalli"))).to be false
    end

    it "keeps the compatibility alias" do
      expect(Langfuse.is_default_export_span(make_span(scope_name: "openinference.instrumentation"))).to be true
    end
  end
end
