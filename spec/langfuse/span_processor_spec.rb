# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::SpanProcessor do
  let(:logger) { instance_double(Logger, error: nil) }
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:config) do
    Langfuse::Config.new do |c|
      c.public_key = "pk_test"
      c.secret_key = "sk_test"
      c.base_url = "https://cloud.langfuse.com"
      c.environment = "production"
      c.release = "release-123"
      c.tracing_async = false
      c.batch_size = 10
      c.flush_interval = 1
      c.logger = logger
    end
  end
  let(:processor) { described_class.new(config: config, exporter: exporter) }
  let(:tracer_provider) do
    OpenTelemetry::SDK::Trace::TracerProvider.new.tap do |provider|
      provider.add_span_processor(processor)
    end
  end

  def exported_span_names
    tracer_provider.force_flush(timeout: 1)
    exporter.finished_spans.map(&:name)
  end

  describe "#on_start" do
    it "sets configured environment and release defaults on new spans" do
      span = tracer_provider.tracer("test").start_span("test-span")

      expect(span.attributes["langfuse.environment"]).to eq("production")
      expect(span.attributes["langfuse.release"]).to eq("release-123")
    end

    it "sets propagated attributes on new spans" do
      span = nil

      Langfuse::Propagation.propagate_attributes(user_id: "user_123", session_id: "session_abc") do
        span = tracer_provider.tracer("test").start_span("test-span")
      end

      expect(span.attributes["user.id"]).to eq("user_123")
      expect(span.attributes["session.id"]).to eq("session_abc")
    end
  end

  describe "#on_finish" do
    it "exports Langfuse spans by default" do
      tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME).start_span("langfuse-span").finish

      expect(exported_span_names).to eq(["langfuse-span"])
    end

    it "drops unknown instrumentation scopes by default" do
      tracer_provider.tracer("dalli").start_span("cache-span").finish

      expect(exported_span_names).to be_empty
    end

    it "exports spans with gen_ai attributes by default" do
      span = tracer_provider.tracer("custom").start_span("genai-span")
      span.set_attribute("gen_ai.system", "openai")
      span.finish

      expect(exported_span_names).to eq(["genai-span"])
    end

    it "exports spans from known LLM instrumentation scopes by default" do
      tracer_provider.tracer("langsmith.client").start_span("known-scope-span").finish

      expect(exported_span_names).to eq(["known-scope-span"])
    end

    it "uses a custom should_export_span filter" do
      config.should_export_span = ->(span) { span.name.start_with?("keep") }
      custom_processor = described_class.new(config: config, exporter: exporter)
      custom_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      custom_provider.add_span_processor(custom_processor)

      custom_provider.tracer("custom").start_span("keep-me").finish
      custom_provider.tracer("custom").start_span("drop-me").finish
      custom_provider.force_flush(timeout: 1)

      expect(exporter.finished_spans.map(&:name)).to eq(["keep-me"])
    end

    it "logs and drops spans when should_export_span raises" do
      config.should_export_span = ->(_span) { raise "boom" }
      custom_processor = described_class.new(config: config, exporter: exporter)
      custom_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      custom_provider.add_span_processor(custom_processor)

      expect(logger).to receive(:error).with(/should_export_span raised/)

      custom_provider.tracer("custom").start_span("drop-me").finish
      custom_provider.force_flush(timeout: 1)

      expect(exporter.finished_spans).to be_empty
    end
  end

  describe "#shutdown" do
    it "does not error" do
      expect { processor.shutdown(timeout: 1) }.not_to raise_error
    end
  end

  describe "#force_flush" do
    it "does not error" do
      expect { processor.force_flush(timeout: 1) }.not_to raise_error
    end
  end
end
