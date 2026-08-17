# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::OtelSetup do
  let(:logger) { instance_double(Logger, info: nil, debug: nil, warn: nil, error: nil) }
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:metrics_reporter) do
    instance_double(
      OpenTelemetry::SDK::Trace::Export::MetricsReporter,
      add_to_counter: nil,
      record_value: nil,
      observe_value: nil
    )
  end
  let(:config) do
    Langfuse::Config.new do |c|
      c.public_key = "pk_test_123"
      c.secret_key = "sk_test_456"
      c.base_url = "https://api.langfuse.test"
      c.tracing_async = false
      c.batch_size = 10
      c.flush_interval = 1
      c.logger = logger
      c.span_exporter = exporter
    end
  end

  before do
    described_class.shutdown(timeout: 1) if described_class.initialized?
  end

  after do
    described_class.shutdown(timeout: 1) if described_class.initialized?
  end

  describe ".setup" do
    it "initializes the tracer provider" do
      described_class.setup(config)

      expect(described_class.tracer_provider).to be_a(OpenTelemetry::SDK::Trace::TracerProvider)
      expect(described_class.initialized?).to be true
    end

    it "does not mutate the global tracer provider" do
      original_global_provider = OpenTelemetry.tracer_provider

      described_class.setup(config)

      expect(OpenTelemetry.tracer_provider).to eq(original_global_provider)
    end

    it "does not mutate the global propagator" do
      original_global_propagation = OpenTelemetry.propagation

      described_class.setup(config)

      expect(OpenTelemetry.propagation).to eq(original_global_propagation)
    end

    it "reuses the existing provider for identical tracing config" do
      provider = described_class.setup(config)

      expect(logger).to receive(:debug).with(/reusing existing tracer provider/)
      expect(described_class.setup(config)).to equal(provider)
    end

    it "warns and keeps the existing provider when tracing config changes" do
      provider = described_class.setup(config)
      config.environment = "staging"

      expect(logger).to receive(:warn).with(/require Langfuse.reset!/)
      expect(described_class.setup(config)).to equal(provider)
    end

    it "requires reset before a replacement metrics reporter takes effect" do
      first_reporter = instance_double(
        OpenTelemetry::SDK::Trace::Export::MetricsReporter,
        add_to_counter: nil,
        record_value: nil,
        observe_value: nil
      )
      second_reporter = instance_double(
        OpenTelemetry::SDK::Trace::Export::MetricsReporter,
        add_to_counter: nil,
        record_value: nil,
        observe_value: nil
      )
      config.metrics_reporter = first_reporter
      provider = described_class.setup(config)
      config.metrics_reporter = second_reporter

      expect(logger).to receive(:warn).with(/metrics_reporter.*require Langfuse.reset!/)

      expect(described_class.setup(config)).to equal(provider)
    end

    it "keeps an injected exporter live during concurrent setup" do
      providers = Queue.new
      threads = 5.times.map { Thread.new { providers << described_class.setup(config) } }
      threads.each(&:join)

      resolved = 5.times.map { providers.pop }
      expect(resolved.map(&:object_id).uniq.length).to eq(1)
      expect(exporter.export([])).to eq(OpenTelemetry::SDK::Trace::Export::SUCCESS)
    end

    it "validates should_export_span in setup" do
      config.should_export_span = "bad"

      expect { described_class.setup(config) }.to raise_error(
        Langfuse::ConfigurationError,
        "should_export_span must respond to #call"
      )
    end

    it "rejects invalid batch_size before building the span processor" do
      config.batch_size = "abc"
      Langfuse.configuration = config

      expect(described_class).not_to receive(:build_tracer_provider)
      expect { Langfuse.tracer_provider }.to raise_error(
        Langfuse::ConfigurationError,
        /batch_size/
      )
    end

    it "validates mask_otel_spans in setup" do
      config.mask_otel_spans = "bad"

      expect { described_class.setup(config) }.to raise_error(
        Langfuse::ConfigurationError,
        "mask_otel_spans must respond to #call"
      )
    end

    context "with sample_rate below 1.0" do
      before do
        config.sample_rate = 0.1
      end

      it "uses TraceIdRatioBased sampler" do
        described_class.setup(config)

        expect(described_class.tracer_provider.sampler).to be_a(OpenTelemetry::SDK::Trace::Samplers::TraceIdRatioBased)
      end

      it "makes deterministic decisions for the same trace id" do
        described_class.setup(config)

        sampler = described_class.tracer_provider.sampler
        trace_id = ["aabbccddeeff00112233445566778899"].pack("H*")
        decision_one = sampler.should_sample?(
          trace_id: trace_id,
          parent_context: nil,
          links: [],
          name: "score",
          kind: OpenTelemetry::Trace::SpanKind::INTERNAL,
          attributes: {}
        ).sampled?
        decision_two = sampler.should_sample?(
          trace_id: trace_id,
          parent_context: nil,
          links: [],
          name: "score",
          kind: OpenTelemetry::Trace::SpanKind::INTERNAL,
          attributes: {}
        ).sampled?

        expect(decision_one).to eq(decision_two)
      end
    end

    context "with sample_rate at 1.0" do
      before do
        config.sample_rate = 1.0
      end

      it "uses always-on sampling behavior" do
        described_class.setup(config)

        sampler = described_class.tracer_provider.sampler
        decision = sampler.should_sample?(
          trace_id: ["00112233445566778899aabbccddeeff"].pack("H*"),
          parent_context: nil,
          links: [],
          name: "score",
          kind: OpenTelemetry::Trace::SpanKind::INTERNAL,
          attributes: {}
        )

        expect(decision.sampled?).to be(true)
      end
    end
  end

  describe ".build_exporter transport" do
    it "uses an injected exporter without constructing OTLP" do
      expect(OpenTelemetry::Exporter::OTLP::Exporter).not_to receive(:new)

      expect(described_class.send(:build_exporter, config)).to equal(exporter)
    end

    it "configures direct v4 OTLP ingestion without changing transport settings" do
      config.span_exporter = nil
      expected_headers = {
        "Authorization" => "Basic #{Base64.strict_encode64('pk_test_123:sk_test_456')}",
        "x-langfuse-ingestion-version" => "4",
        "x-langfuse-sdk-name" => "ruby",
        "x-langfuse-sdk-version" => Langfuse::VERSION,
        "x-langfuse-public-key" => "pk_test_123"
      }

      allow(described_class).to receive(:build_exporter).and_call_original
      expect(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new).with(
        endpoint: "https://api.langfuse.test/api/public/otel/v1/traces",
        headers: expected_headers,
        compression: "gzip"
      ).and_return(exporter)

      expect(described_class.send(:build_exporter, config)).to equal(exporter)
    end
  end

  describe ".shutdown" do
    it "is safe before initialization" do
      expect { described_class.shutdown(timeout: 1) }.not_to raise_error
    end
  end

  describe ".force_flush" do
    it "is safe before initialization" do
      expect { described_class.force_flush(timeout: 1) }.not_to raise_error
    end
  end

  describe "lazy module-level setup" do
    it "does not initialize tracing during Langfuse.configure" do
      Langfuse.configure do |c|
        c.public_key = config.public_key
        c.secret_key = config.secret_key
        c.base_url = config.base_url
        c.logger = logger
      end

      expect(described_class.initialized?).to be false
    end

    it "raises from Langfuse.tracer_provider when tracing is not ready" do
      Langfuse.reset!
      Langfuse.configure do |c|
        c.public_key = nil
        c.secret_key = nil
        c.base_url = nil
        c.logger = logger
      end

      expect { Langfuse.tracer_provider }.to raise_error(
        Langfuse::ConfigurationError,
        /Langfuse tracing is disabled/
      )
    end

    it "initializes once when Langfuse.tracer_provider is called concurrently" do
      Langfuse.reset!
      Langfuse.configure do |c|
        c.public_key = config.public_key
        c.secret_key = config.secret_key
        c.base_url = config.base_url
        c.logger = logger
      end

      providers = Queue.new
      threads = 5.times.map do
        Thread.new { providers << Langfuse.tracer_provider }
      end
      threads.each(&:join)

      resolved = 5.times.map { providers.pop }
      expect(resolved.map(&:object_id).uniq.length).to eq(1)
    end
  end

  describe "export behavior" do
    before do
      Langfuse.reset!
      Langfuse.configure do |c|
        c.public_key = config.public_key
        c.secret_key = config.secret_key
        c.base_url = config.base_url
        c.tracing_async = false
        c.batch_size = 10
        c.flush_interval = 1
        c.logger = logger
        c.span_exporter = exporter
      end
    end

    it "exports Langfuse-created spans without exporting ambient global spans" do
      OpenTelemetry.tracer_provider.tracer("dalli").start_span("cache-span").finish
      span = Langfuse.observe("langfuse-span")
      span.end
      Langfuse.force_flush(timeout: 1)

      expect(exporter.finished_spans.map(&:name)).to eq(["langfuse-span"])
    end

    it "drops buffered spans when telemetry is disabled before export" do
      Langfuse.observe("before-disable").end

      Langfuse.configure { |c| c.tracing_enabled = false }
      Langfuse.force_flush(timeout: 1)

      expect(exporter.finished_spans).to be_empty
    end

    it "exports new spans after telemetry is re-enabled" do
      Langfuse.observe("before-disable").end
      Langfuse.configure { |c| c.tracing_enabled = false }
      Langfuse.force_flush(timeout: 1)

      Langfuse.configure { |c| c.tracing_enabled = true }
      Langfuse.observe("after-enable").end
      Langfuse.force_flush(timeout: 1)

      expect(exporter.finished_spans.map(&:name)).to eq(["after-enable"])
    end

    it "exports each completed observation once" do
      Langfuse.observe("root") do |root|
        root.start_observation("generation", as_type: :generation) { |generation| generation.update(output: "ok") }
        root.start_observation("child") { |child| child.update(output: "ok") }
      end
      Langfuse.force_flush(timeout: 1)

      exported_ids = exporter.finished_spans.map(&:hex_span_id)
      expect(exporter.finished_spans.map(&:name)).to contain_exactly("root", "generation", "child")
      expect(exported_ids.uniq.length).to eq(3)
    end

    it "exports known LLM scopes after explicit global installation" do
      OpenTelemetry.tracer_provider = Langfuse.tracer_provider
      OpenTelemetry.tracer_provider.tracer("langsmith.client").start_span("global-span").finish
      Langfuse.force_flush(timeout: 1)

      expect(exporter.finished_spans.map(&:name)).to eq(["global-span"])
    end

    it "allows custom filters to drop globally installed spans again" do
      Langfuse.reset!
      Langfuse.configure do |c|
        c.public_key = config.public_key
        c.secret_key = config.secret_key
        c.base_url = config.base_url
        c.tracing_async = false
        c.should_export_span = ->(_span) { false }
        c.logger = logger
        c.span_exporter = exporter
      end

      OpenTelemetry.tracer_provider = Langfuse.tracer_provider
      OpenTelemetry.tracer_provider.tracer("langsmith.client").start_span("global-span").finish
      Langfuse.force_flush(timeout: 1)

      expect(exporter.finished_spans).to be_empty
    end

    it "keeps filtering, defaults, app-root tracking, and metrics in the injected pipeline" do
      Langfuse.reset!
      Langfuse.configure do |c|
        c.public_key = config.public_key
        c.secret_key = config.secret_key
        c.tracing_async = false
        c.environment = "test"
        c.release = "release-123"
        c.should_export_span = ->(span) { span.name != "drop-me" }
        c.metrics_reporter = metrics_reporter
        c.span_exporter = exporter
        c.logger = logger
      end

      Langfuse.observe("root") do |root|
        root.start_observation("child") { |child| child.update(output: "ok") }
      end
      Langfuse.observe("drop-me") { |span| span.update(output: "discarded") }
      Langfuse.force_flush(timeout: 1)

      spans = exporter.finished_spans.to_h { |span| [span.name, span] }
      expect(spans.keys).to contain_exactly("root", "child")
      expect(spans.fetch("root").attributes).to include(
        Langfuse::OtelAttributes::ENVIRONMENT => "test",
        Langfuse::OtelAttributes::RELEASE => "release-123",
        Langfuse::OtelAttributes::IS_APP_ROOT => true
      )
      expect(metrics_reporter).to have_received(:add_to_counter).with(
        "otel.bsp.exported_spans", increment: 2, labels: {}
      )
    end
  end

  describe ".build_exporter masking" do
    before do
      allow(described_class).to receive(:build_exporter).and_call_original
    end

    it "returns the plain OTLP exporter when mask_otel_spans is nil" do
      config.span_exporter = nil
      expect(described_class.send(:build_exporter, config)).to be_a(OpenTelemetry::Exporter::OTLP::Exporter)
    end

    it "wraps an injected exporter in a MaskingExporter when mask_otel_spans is configured" do
      config.mask_otel_spans = ->(**) {}
      allow(exporter).to receive(:force_flush).and_call_original

      masked_exporter = described_class.send(:build_exporter, config)
      masked_exporter.force_flush(timeout: 1)

      expect(masked_exporter).to be_a(Langfuse::MaskingExporter)
      expect(exporter).to have_received(:force_flush).with(timeout: 1)
    end
  end

  describe "export-stage masking" do
    let(:seen_spans) { [] }
    let(:mask_hook) do
      lambda do |params:|
        seen_spans.concat(params.spans.values)
        patches = params.spans.filter_map do |id, snapshot|
          next unless snapshot.attributes.key?("gen_ai.prompt")

          [id, Langfuse::OtelSpanPatch.new(set_attributes: { "gen_ai.prompt" => "<redacted>" })]
        end.to_h
        Langfuse::MaskOtelSpansResult.new(span_patches: patches)
      end
    end

    before do
      allow(described_class).to receive(:build_exporter).and_call_original
      Langfuse.reset!
      Langfuse.configure do |c|
        c.public_key = config.public_key
        c.secret_key = config.secret_key
        c.base_url = config.base_url
        c.tracing_async = false
        c.mask_otel_spans = mask_hook
        c.span_exporter = exporter
        c.logger = logger
      end
    end

    it "masks accepted third-party gen_ai spans on the Langfuse export copy" do
      tracer = Langfuse.tracer_provider.tracer("langsmith.client")
      tracer.start_span("llm-call", attributes: { "gen_ai.prompt" => "secret" }).finish
      Langfuse.force_flush(timeout: 1)

      exported = exporter.finished_spans.find { |span| span.name == "llm-call" }
      expect(exported.attributes["gen_ai.prompt"]).to eq("<redacted>")
    end

    it "runs should_export_span before masking so rejected spans never reach the hook" do
      Langfuse.tracer_provider.tracer("dalli").start_span("cache-span").finish
      tracer = Langfuse.tracer_provider.tracer("langsmith.client")
      tracer.start_span("llm-call", attributes: { "gen_ai.prompt" => "x" }).finish
      Langfuse.force_flush(timeout: 1)

      expect(seen_spans.map(&:name)).to eq(["llm-call"])
    end
  end

  describe "injected exporter lifecycle" do
    def build_config(span_exporter)
      Langfuse::Config.new do |candidate|
        candidate.public_key = "pk_test"
        candidate.secret_key = "sk_test"
        candidate.tracing_async = false
        candidate.span_exporter = span_exporter
        candidate.logger = logger
      end
    end

    def finish_span(provider, name)
      provider.tracer(Langfuse::LANGFUSE_TRACER_NAME).start_span(name).finish
    end

    it "warns and keeps the active exporter until reset" do
      replacement = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
      provider = described_class.setup(config)
      config.span_exporter = replacement

      expect(logger).to receive(:warn).with(/span_exporter.*require Langfuse.reset!/)
      expect(described_class.setup(config)).to equal(provider)
      finish_span(provider, "first-exporter")
      described_class.force_flush(timeout: 1)

      expect(exporter.finished_spans.map(&:name)).to eq(["first-exporter"])
      expect(replacement.finished_spans).to be_empty
    end

    it "shuts down the injected exporter with its provider" do
      described_class.setup(config)

      described_class.shutdown(timeout: 1)

      expect(exporter.export([])).to eq(OpenTelemetry::SDK::Trace::Export::FAILURE)
    end

    it "shuts down the injected exporter during Langfuse.reset!" do
      Langfuse.configuration = config
      Langfuse.tracer_provider

      Langfuse.reset!

      expect(exporter.export([])).to eq(OpenTelemetry::SDK::Trace::Export::FAILURE)
    end

    it "keeps consecutive exporter sessions isolated" do
      first_provider = described_class.setup(config)
      finish_span(first_provider, "first-session")
      described_class.force_flush(timeout: 1)
      expect(exporter.finished_spans.map(&:name)).to eq(["first-session"])
      described_class.shutdown(timeout: 1)

      second_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
      second_provider = described_class.setup(build_config(second_exporter))
      finish_span(second_provider, "second-session")
      described_class.force_flush(timeout: 1)

      expect(second_exporter.finished_spans.map(&:name)).to eq(["second-session"])
    end

    it "does not send a late span from a stopped provider to the next exporter" do
      first_provider = described_class.setup(config)
      late_span = first_provider.tracer(Langfuse::LANGFUSE_TRACER_NAME).start_span("late-first")
      described_class.shutdown(timeout: 1)

      second_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
      second_provider = described_class.setup(build_config(second_exporter))
      finish_span(second_provider, "second-session")
      late_span.finish
      described_class.force_flush(timeout: 1)

      expect(second_exporter.finished_spans.map(&:name)).to eq(["second-session"])
    end
  end
end
