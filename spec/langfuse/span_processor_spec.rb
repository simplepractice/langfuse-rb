# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::SpanProcessor do
  let(:logger) { instance_double(Logger, debug: nil, error: nil) }
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

  def exported_spans_by_name
    tracer_provider.force_flush(timeout: 1)
    exporter.finished_spans.to_h { |span| [span.name, span] }
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

    it "marks only the exported parent as the application root" do
      tracer = tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME)
      parent = tracer.start_span("parent")
      parent_context = OpenTelemetry::Trace.context_with_span(parent)
      child = OpenTelemetry::Context.with_current(parent_context) { tracer.start_span("child") }

      child.finish
      parent.finish
      spans = exported_spans_by_name

      expect(spans.fetch("parent").attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
      expect(spans.fetch("child").attributes).not_to have_key(Langfuse::OtelAttributes::IS_APP_ROOT)
    end

    it "marks an exported child when its parent is filtered" do
      filtered_parent = tracer_provider.tracer("rack").start_span("request")
      parent_context = OpenTelemetry::Trace.context_with_span(filtered_parent)
      child = OpenTelemetry::Context.with_current(parent_context) do
        tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME).start_span("workflow")
      end

      child.finish
      filtered_parent.finish
      spans = exported_spans_by_name

      expect(spans).not_to have_key("request")
      expect(spans.fetch("workflow").attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
    end

    it "uses the trace baggage claim to prevent a second application root" do
      langfuse_tracer = tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME)
      root = langfuse_tracer.start_span("root")
      root_context = OpenTelemetry::Trace.context_with_span(root)
      claimed_context = Langfuse::Propagation._set_langfuse_trace_id_in_baggage(
        root.context.trace_id.unpack1("H*"), context: root_context
      )
      intermediary = OpenTelemetry::Context.with_current(claimed_context) do
        tracer_provider.tracer("rack").start_span("intermediary")
      end
      intermediary_context = OpenTelemetry::Trace.context_with_span(
        intermediary, parent_context: claimed_context
      )
      child = OpenTelemetry::Context.with_current(intermediary_context) do
        langfuse_tracer.start_span("child")
      end

      child.finish
      intermediary.finish
      root.finish
      spans = exported_spans_by_name

      expect(spans.fetch("root").attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
      expect(spans.fetch("child").attributes).not_to have_key(Langfuse::OtelAttributes::IS_APP_ROOT)
    end

    it "honors a trace claim from an untracked parent" do
      trace_id = OpenTelemetry::Trace.generate_trace_id
      parent_context = OpenTelemetry::Trace::SpanContext.new(
        trace_id: trace_id,
        span_id: OpenTelemetry::Trace.generate_span_id,
        trace_flags: OpenTelemetry::Trace::TraceFlags::SAMPLED
      )
      parent_span = OpenTelemetry::Trace.non_recording_span(parent_context)
      context = OpenTelemetry::Trace.context_with_span(parent_span)
      claimed_context = Langfuse::Propagation._set_langfuse_trace_id_in_baggage(
        trace_id.unpack1("H*"), context: context
      )
      child = OpenTelemetry::Context.with_current(claimed_context) do
        tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME).start_span("child")
      end

      child.finish
      span = exported_spans_by_name.fetch("child")

      expect(span.attributes).not_to have_key(Langfuse::OtelAttributes::IS_APP_ROOT)
    end

    it "marks a root when gen_ai attributes are added after span start" do
      filtered_parent = tracer_provider.tracer("rack").start_span("request")
      parent_context = OpenTelemetry::Trace.context_with_span(filtered_parent)
      generation = OpenTelemetry::Context.with_current(parent_context) do
        tracer_provider.tracer("custom").start_span("generation")
      end
      generation.set_attribute("gen_ai.system", "synthetic")

      generation.finish
      filtered_parent.finish
      spans = exported_spans_by_name

      expect(spans.fetch("generation").attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
    end

    it "encodes an export-time root mark as OTLP" do
      span = tracer_provider.tracer("custom").start_span("generation")
      span.set_attribute("gen_ai.system", "synthetic")
      span.finish
      span_data = exported_spans_by_name.fetch("generation")
      otlp_exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: "http://localhost/api/public/otel/v1/traces"
      )

      expect(otlp_exporter.send(:encode, [span_data])).to be_a(String)
    end

    it "moves the root mark to a parent that gains gen_ai attributes" do
      filtered_parent = tracer_provider.tracer("rack").start_span("request")
      filtered_context = OpenTelemetry::Trace.context_with_span(filtered_parent)
      generation = OpenTelemetry::Context.with_current(filtered_context) do
        tracer_provider.tracer("custom").start_span("generation")
      end
      generation_context = OpenTelemetry::Trace.context_with_span(generation, parent_context: filtered_context)
      child = OpenTelemetry::Context.with_current(generation_context) do
        tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME).start_span("child")
      end
      generation.set_attribute("gen_ai.system", "synthetic")

      child.finish
      generation.finish
      filtered_parent.finish
      spans = exported_spans_by_name

      expect(spans.fetch("generation").attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
      expect(spans.fetch("child").attributes).not_to have_key(Langfuse::OtelAttributes::IS_APP_ROOT)
    end

    it "moves the root mark after the child finishes before its parent becomes exportable" do
      filtered_parent = tracer_provider.tracer("rack").start_span("request")
      filtered_context = OpenTelemetry::Trace.context_with_span(filtered_parent)
      generation = OpenTelemetry::Context.with_current(filtered_context) do
        tracer_provider.tracer("custom").start_span("generation")
      end
      generation_context = OpenTelemetry::Trace.context_with_span(generation, parent_context: filtered_context)
      child = OpenTelemetry::Context.with_current(generation_context) do
        tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME).start_span("child")
      end

      child.finish
      tracer_provider.force_flush(timeout: 1)

      expect(exporter.finished_spans).to be_empty

      generation.set_attribute("gen_ai.system", "synthetic")
      generation.finish
      filtered_parent.finish
      spans = exported_spans_by_name

      expect(spans.fetch("generation").attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
      expect(spans.fetch("child").attributes).not_to have_key(Langfuse::OtelAttributes::IS_APP_ROOT)
    end

    it "retains the root state until children finish" do
      tracer = tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME)
      parent = tracer.start_span("parent")
      parent_context = OpenTelemetry::Trace.context_with_span(parent)
      child = OpenTelemetry::Context.with_current(parent_context) { tracer.start_span("child") }

      parent.finish
      child.finish
      spans = exported_spans_by_name

      expect(spans.fetch("parent").attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
      expect(spans.fetch("child").attributes).not_to have_key(Langfuse::OtelAttributes::IS_APP_ROOT)
    end

    it "treats disjoint entries with one trace ID as separate application roots" do
      trace_id = OpenTelemetry::Trace.generate_trace_id
      tracer = tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME)

      2.times do |index|
        parent_context = OpenTelemetry::Trace::SpanContext.new(
          trace_id: trace_id,
          span_id: OpenTelemetry::Trace.generate_span_id,
          trace_flags: OpenTelemetry::Trace::TraceFlags::SAMPLED
        )
        parent_span = OpenTelemetry::Trace.non_recording_span(parent_context)
        context = OpenTelemetry::Trace.context_with_span(parent_span)
        OpenTelemetry::Context.with_current(context) { tracer.start_span("entry-#{index}").finish }
      end

      roots = exported_spans_by_name.values.select do |span|
        span.attributes[Langfuse::OtelAttributes::IS_APP_ROOT]
      end
      expect(roots.map(&:name)).to contain_exactly("entry-0", "entry-1")
    end

    it "does not mark a LiteLLM raw request with an ended parent as an application root" do
      tracer = tracer_provider.tracer("litellm")
      parent = tracer.start_span("litellm_request")
      parent_context = OpenTelemetry::Trace.context_with_span(parent)
      parent.finish
      raw_request = OpenTelemetry::Context.with_current(parent_context) do
        tracer.start_span("raw_gen_ai_request")
      end
      raw_request.finish
      spans = exported_spans_by_name

      expect(spans.fetch("litellm_request").attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
      expect(spans.fetch("raw_gen_ai_request").attributes).not_to have_key(Langfuse::OtelAttributes::IS_APP_ROOT)
    end

    it "marks a LiteLLM raw request when its tracked parent is filtered" do
      filtered_parent = tracer_provider.tracer("rack").start_span("request")
      parent_context = OpenTelemetry::Trace.context_with_span(filtered_parent)
      raw_request = OpenTelemetry::Context.with_current(parent_context) do
        tracer_provider.tracer("litellm").start_span("raw_gen_ai_request")
      end

      raw_request.finish
      filtered_parent.finish
      spans = exported_spans_by_name

      expect(spans).not_to have_key("request")
      expect(spans.fetch("raw_gen_ai_request").attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
    end

    it "marks a parentless LiteLLM raw request as an application root" do
      tracer_provider.tracer("litellm").start_span("raw_gen_ai_request").finish

      span = exported_spans_by_name.fetch("raw_gen_ai_request")

      expect(span.attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
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

    it "marks an attribute-free known instrumentor span as the root" do
      config.environment = nil
      config.release = nil
      custom_processor = described_class.new(config: config, exporter: exporter)
      custom_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      custom_provider.add_span_processor(custom_processor)

      custom_provider.tracer("langsmith.client").start_span("attribute-free-span").finish
      custom_provider.force_flush(timeout: 1)
      exported_span = exporter.finished_spans.fetch(0)

      expect(exported_span.attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
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

    it "promotes a child when a custom filter rejects its claimed local root" do
      config.should_export_span = ->(span) { span.name == "child" }
      custom_processor = described_class.new(config: config, exporter: exporter)
      custom_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      custom_provider.add_span_processor(custom_processor)
      tracer = custom_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME)
      root = tracer.start_span("root")
      root_context = OpenTelemetry::Trace.context_with_span(root)
      claimed_context = Langfuse::Propagation._set_langfuse_trace_id_in_baggage(
        root.context.trace_id.unpack1("H*"), context: root_context
      )
      child = OpenTelemetry::Context.with_current(claimed_context) { tracer.start_span("child") }

      child.finish
      root.finish
      custom_provider.force_flush(timeout: 1)
      exported_span = exporter.finished_spans.fetch(0)

      expect(exported_span.name).to eq("child")
      expect(exported_span.attributes[Langfuse::OtelAttributes::IS_APP_ROOT]).to be(true)
    end

    it "calls a custom filter once with the finished span" do
      filter = instance_double(Proc, call: true)
      config.should_export_span = filter
      custom_processor = described_class.new(config: config, exporter: exporter)
      custom_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
      custom_provider.add_span_processor(custom_processor)

      custom_provider.tracer("custom").start_span("span").finish
      custom_provider.force_flush(timeout: 1)

      expect(filter).to have_received(:call).once
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

    it "logs and drops a span when application-root tracking fails" do
      app_root_tracker = processor.instance_variable_get(:@app_root_tracker)
      allow(app_root_tracker).to receive(:remember).and_raise("boom")
      expect(logger).to receive(:error).with(/span will not export/)

      tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME).start_span("drop-me").finish
      tracer_provider.force_flush(timeout: 1)

      expect(exporter.finished_spans).to be_empty
    end

    it "clears application-root tracking after spans finish" do
      tracer = tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME)
      tracer.start_span("root").finish

      exported_span_names

      app_root_tracker = processor.instance_variable_get(:@app_root_tracker)
      expect(app_root_tracker).to be_empty
    end

    it "keeps application-root tracking consistent across threads" do
      tracer = tracer_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME)
      threads = 8.times.map do |index|
        Thread.new do
          parent = tracer.start_span("parent-#{index}")
          parent_context = OpenTelemetry::Trace.context_with_span(parent)
          child = OpenTelemetry::Context.with_current(parent_context) do
            tracer.start_span("child-#{index}")
          end
          child.finish
          parent.finish
        end
      end
      threads.each(&:value)

      spans = exported_spans_by_name
      roots = spans.values.select { |span| span.name.start_with?("parent-") }
      app_root_tracker = processor.instance_variable_get(:@app_root_tracker)

      expect(roots).to all(satisfy { |span| span.attributes[Langfuse::OtelAttributes::IS_APP_ROOT] })
      expect(app_root_tracker).to be_empty
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
