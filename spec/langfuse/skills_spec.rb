# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Skill availability tracing" do
  let(:skill_key) { Langfuse::OtelAttributes::OBSERVATION_SKILLS_AVAILABLE }
  let(:catalog) { [{ name: "catalog-skill", version: 2 }] }
  let(:explicit) { [{ name: "explicit-skill", version: 3, source: "local" }] }
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  before do
    Langfuse.configure do |config|
      config.skills = { available: catalog }
      config.span_exporter = exporter
    end
  end

  def record_skills(name = "skill-span")
    Langfuse.observe(name) { |span| span.otel_span.attributes&.fetch(skill_key, nil) }
  end

  it "does not attach configured skills by default" do
    expect(record_skills).to be_nil
  end

  it "attaches the configured snapshot only to new spans within opted-in scopes" do
    Langfuse.observe("existing") do |existing|
      Langfuse.propagate_attributes(attach_skills: true) do
        expect(existing.otel_span.attributes).not_to have_key(skill_key)
        expect(JSON.parse(record_skills)).to eq(catalog.map { |skill| skill.transform_keys(&:to_s) })
        catalog.first[:name] = "mutated"
        expect(JSON.parse(record_skills).first["name"]).to eq("catalog-skill")
      end
      expect(record_skills("outside")).to be_nil
    end
  end

  it "inherits catalog attachment and restores it after a nested opt-out" do
    Langfuse.propagate_attributes(attach_skills: true) do
      Langfuse.propagate_attributes { expect(record_skills).to eq(catalog.to_json) }
      Langfuse.propagate_attributes(attach_skills: false) { expect(record_skills).to be_nil }
      expect(record_skills).to eq(catalog.to_json)
    end
  end

  it "ignores non-Boolean attachment values" do
    Langfuse.propagate_attributes(attach_skills: "true") { expect(record_skills).to be_nil }
    Langfuse.propagate_attributes(attach_skills: true) do
      Langfuse.propagate_attributes(attach_skills: "false") { expect(record_skills).to eq(catalog.to_json) }
    end
  end

  it "sets explicit skills on the active span and children without dropping unknown fields" do
    Langfuse.observe("parent") do |parent|
      Langfuse.propagate_attributes(skills_available: explicit) do
        expect(parent.otel_span.attributes[skill_key]).to eq(explicit.to_json)
        parent.start_observation("child") do |child|
          expect(child.otel_span.attributes[skill_key]).to eq(explicit.to_json)
        end
      end
      expect(record_skills("sibling")).to be_nil
    end
  end

  it "replaces inherited lists, clears them explicitly, and restores outer context after exceptions" do
    Langfuse.propagate_attributes(skills_available: catalog, attach_skills: true) do
      Langfuse.propagate_attributes(skills_available: explicit) { expect(record_skills).to eq(explicit.to_json) }
      expect do
        Langfuse.propagate_attributes(skills_available: []) do
          expect(record_skills).to eq("[]")
          raise "scope failed"
        end
      end.to raise_error("scope failed")
      expect(record_skills).to eq(catalog.to_json)
    end
    expect(record_skills).to be_nil
  end

  it "lets explicit empty skills override catalog attachment and clears the active span" do
    Langfuse.propagate_attributes(attach_skills: true) do
      Langfuse.observe("parent") do |parent|
        Langfuse.propagate_attributes(skills_available: []) do
          expect(parent.otel_span.attributes[skill_key]).to eq("[]")
          expect(record_skills).to eq("[]")
        end
      end
    end
  end

  it "preserves explicit skills even when catalog attachment is disabled" do
    Langfuse.propagate_attributes(skills_available: explicit, attach_skills: false) do
      expect(record_skills).to eq(explicit.to_json)
    end
  end

  it "preserves skills supplied directly to an OpenTelemetry span ahead of context and catalog" do
    tracer = Langfuse.tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME)
    Langfuse.propagate_attributes(skills_available: explicit, attach_skills: true) do
      span = tracer.start_span("direct", attributes: { skill_key => "[]" })
      expect(span.attributes[skill_key]).to eq("[]")
      span.finish
    end
  end

  it "attaches the catalog to third-party instrumented spans" do
    tracer = Langfuse.tracer_provider.tracer("openai")
    Langfuse.propagate_attributes(attach_skills: true) do
      span = tracer.start_span("generation")
      expect(span.attributes[skill_key]).to eq(catalog.to_json)
      span.finish
    end
  end

  it "serializes scope values immediately so caller mutations cannot change inherited skills" do
    Langfuse.propagate_attributes(skills_available: explicit) do
      explicit.first[:name] = "changed"
      expect(JSON.parse(record_skills).first["name"]).to eq("explicit-skill")
    end
  end

  it "does not put skills or attachment flags in baggage" do
    baggage = Module.new
    allow(baggage).to receive(:set_value) { |_key, _value, context:| context }
    stub_const("OpenTelemetry::Baggage", baggage)

    Langfuse.propagate_attributes(skills_available: explicit, attach_skills: true, as_baggage: true) {}

    expect(baggage).not_to have_received(:set_value)
  end

  it "does not import skills or attachment flags from incoming baggage" do
    baggage = Module.new
    allow(baggage).to receive(:values).and_return(
      "langfuse_skills_available" => explicit.to_json, "langfuse_attach_skills" => "true"
    )
    stub_const("OpenTelemetry::Baggage", baggage)

    expect(record_skills).to be_nil
  end

  it "isolates simultaneous scopes between threads" do
    Langfuse.tracer_provider
    ready = Queue.new
    proceed = Queue.new
    threads = 2.times.map do |index|
      Thread.new do
        Langfuse.propagate_attributes(skills_available: [{ name: "skill-#{index}" }]) do
          ready << true
          proceed.pop
          record_skills
        end
      end
    end
    2.times { ready.pop }
    2.times { proceed << true }

    expect(threads.map(&:value)).to eq(['[{"name":"skill-0"}]', '[{"name":"skill-1"}]'])
    expect(record_skills).to be_nil
  end

  it "exports skill attributes without creating skill execution observations" do
    Langfuse.propagate_attributes(skills_available: explicit) { record_skills("agent") }
    Langfuse.force_flush

    expect(exporter.finished_spans.map(&:name)).to eq(["agent"])
    expect(exporter.finished_spans.first.attributes[skill_key]).to eq(explicit.to_json)
  end

  it "allows opt-in without a configured catalog" do
    Langfuse.configuration.skills = nil
    Langfuse.propagate_attributes(attach_skills: true) { expect(record_skills).to be_nil }
  end

  it "attaches an explicitly empty catalog" do
    Langfuse.configuration.skills = { available: [] }
    Langfuse.propagate_attributes(attach_skills: true) { expect(record_skills).to eq("[]") }
  end

  it "drops unserializable values with a warning while preserving inherited skills" do
    logger = Langfuse.configuration.logger
    allow(logger).to receive(:warn)
    recursive = []
    recursive << recursive
    Langfuse.propagate_attributes(skills_available: explicit) do
      Langfuse.propagate_attributes(skills_available: recursive) { expect(record_skills).to eq(explicit.to_json) }
      Langfuse.propagate_attributes(skills_available: [{ name: "nan", version: Float::NAN }]) do
        expect(record_skills).to eq(explicit.to_json)
      end
    end
    expect(logger).to have_received(:warn).with(/Failed to serialize available skills/).twice
  end

  %w[LANGFUSE_TRACING_ENABLED OTEL_SDK_DISABLED].each do |variable|
    it "makes no network calls or exports when #{variable} disables tracing" do
      ENV[variable] = variable == "OTEL_SDK_DISABLED" ? "true" : "false"
      Langfuse.configuration = Langfuse::Config.new
      Langfuse.configuration.skills = { available: catalog }
      Langfuse.configuration.span_exporter = exporter
      WebMock.reset_executed_requests!

      Langfuse.propagate_attributes(skills_available: explicit, attach_skills: true) do
        Langfuse.observe("disabled") { |span| expect(span.otel_span).not_to be_recording }
      end
      Langfuse.force_flush

      expect(exporter.finished_spans).to be_empty
      expect(a_request(:any, /.*/)).not_to have_been_made
    ensure
      ENV.delete(variable)
    end
  end
end
