# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::MaskingExporter do
  let(:logger) { instance_double(Logger, error: nil, warn: nil) }
  let(:delegate) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:hook) { ->(**) {} }
  let(:exporter) { described_class.new(delegate: delegate, hook: hook, logger: logger) }

  let(:langfuse_span) do
    build_span_data(name: "langfuse-span", scope_name: "langfuse",
                    attributes: { "langfuse.observation.input" => "secret input" })
  end
  let(:third_party_span) do
    # Unfrozen attribute values so specs can prove snapshots copy rather than
    # freeze the originals.
    build_span_data(name: "chat gpt-4o", scope_name: "ruby-openai",
                    attributes: { "gen_ai.prompt" => +"ssn 123-45-6789", "gen_ai.system" => +"openai" })
  end

  def batch
    [langfuse_span, third_party_span]
  end

  def build_span_data(name:, scope_name:, attributes: {})
    OpenTelemetry::SDK::Trace::SpanData.new(
      name, :internal, OpenTelemetry::Trace::Status.ok, OpenTelemetry::Trace::INVALID_SPAN_ID,
      attributes.size, 0, 0, 1_000, 2_000, attributes, nil, nil,
      OpenTelemetry::SDK::Resources::Resource.create({ "service.name" => "test-app" }),
      OpenTelemetry::SDK::InstrumentationScope.new(scope_name, "1.0.0"),
      OpenTelemetry::Trace.generate_span_id, OpenTelemetry::Trace.generate_trace_id,
      OpenTelemetry::Trace::TraceFlags::DEFAULT, OpenTelemetry::Trace::Tracestate::DEFAULT, false
    )
  end

  def identifier(span)
    "#{span.hex_trace_id}:#{span.hex_span_id}"
  end

  describe "#export" do
    context "when the hook returns nil" do
      it "exports the original batch unchanged" do
        result = exporter.export(batch)

        expect(result).to eq(OpenTelemetry::SDK::Trace::Export::SUCCESS)
        expect(delegate.finished_spans.map(&:name)).to eq(["langfuse-span", "chat gpt-4o"])
      end

      it "passes through the original span objects" do
        exporter.export(batch)

        expect(delegate.finished_spans[0]).to equal(langfuse_span)
        expect(delegate.finished_spans[1]).to equal(third_party_span)
      end
    end

    context "with snapshots given to the hook" do
      let(:seen) { [] }
      let(:hook) do
        lambda do |spans:|
          seen << spans
          nil
        end
      end

      it "exposes both Langfuse-owned and third-party spans" do
        exporter.export(batch)

        expect(seen.first.keys).to contain_exactly(identifier(langfuse_span), identifier(third_party_span))
      end

      it "exposes trace/span ids, name, scope, and frozen attributes" do
        exporter.export(batch)

        snapshot = seen.first[identifier(third_party_span)]
        expect(snapshot.trace_id).to eq(third_party_span.hex_trace_id)
        expect(snapshot.span_id).to eq(third_party_span.hex_span_id)
        expect(snapshot.name).to eq("chat gpt-4o")
        expect(snapshot.scope_name).to eq("ruby-openai")
        expect(snapshot.attributes).to be_frozen
        expect(snapshot.attributes["gen_ai.prompt"]).to be_frozen
        expect(snapshot.resource_attributes).to include("service.name" => "test-app")
      end

      it "gives the hook a frozen mapping" do
        exporter.export(batch)

        expect(seen.first).to be_frozen
      end

      it "does not freeze the original span attribute values" do
        exporter.export(batch)

        expect(third_party_span.attributes["gen_ai.prompt"]).not_to be_frozen
      end
    end

    context "with sparse patches" do
      let(:hook) do
        lambda do |spans:|
          target = spans.values.find { |snapshot| snapshot.scope_name == "ruby-openai" }
          {
            "#{target.trace_id}:#{target.span_id}" => {
              delete: ["gen_ai.prompt"],
              set: { "gen_ai.prompt.masked" => true }
            }
          }
        end
      end

      it "deletes and sets attributes on the exported copy" do
        exporter.export(batch)

        masked = delegate.finished_spans.find { |span| span.name == "chat gpt-4o" }
        expect(masked.attributes).to eq("gen_ai.system" => "openai", "gen_ai.prompt.masked" => true)
      end

      it "leaves unpatched spans as the original objects" do
        exporter.export(batch)

        expect(delegate.finished_spans.find { |span| span.name == "langfuse-span" }).to equal(langfuse_span)
      end

      it "never mutates the original span data" do
        exporter.export(batch)

        expect(third_party_span.attributes).to eq(
          "gen_ai.prompt" => "ssn 123-45-6789", "gen_ai.system" => "openai"
        )
      end
    end

    context "with delete-then-set precedence" do
      let(:hook) do
        lambda do |spans:|
          spans.each_key.to_h do |id|
            [id, { delete: ["gen_ai.prompt"], set: { "gen_ai.prompt" => "<redacted>" } }]
          end
        end
      end

      it "lets the replacement win when a key appears in both" do
        exporter.export([third_party_span])

        expect(delegate.finished_spans.first.attributes["gen_ai.prompt"]).to eq("<redacted>")
      end
    end

    context "when the hook raises" do
      let(:hook) { ->(**) { raise "boom" } }

      it "drops the whole batch and returns FAILURE" do
        result = exporter.export(batch)

        expect(result).to eq(OpenTelemetry::SDK::Trace::Export::FAILURE)
        expect(delegate.finished_spans).to be_empty
      end

      it "logs a sanitized error" do
        exporter.export(batch)

        expect(logger).to have_received(:error).with(/mask_otel_spans raised RuntimeError/)
      end
    end

    context "when the hook returns an invalid top-level result" do
      let(:hook) { ->(**) { "not a hash" } }

      it "drops the whole batch and returns FAILURE" do
        result = exporter.export(batch)

        expect(result).to eq(OpenTelemetry::SDK::Trace::Export::FAILURE)
        expect(delegate.finished_spans).to be_empty
        expect(logger).to have_received(:error).with(/returned String/)
      end
    end

    context "when one span patch is malformed" do
      let(:hook) do
        lambda do |spans:|
          langfuse_id, third_party_id = spans.keys
          {
            langfuse_id => "not a patch",
            third_party_id => { delete: ["gen_ai.prompt"] }
          }
        end
      end

      it "drops only that span and keeps the rest of the batch" do
        exporter.export(batch)

        expect(delegate.finished_spans.map(&:name)).to eq(["chat gpt-4o"])
        expect(logger).to have_received(:error).with(/malformed patch for span 'langfuse-span'/)
      end
    end

    context "when a patch has unknown keys" do
      let(:hook) do
        ->(spans:) { spans.each_key.to_h { |id| [id, { remove: ["gen_ai.prompt"] }] } }
      end

      it "treats the patch as malformed and drops the span" do
        exporter.export([third_party_span])

        expect(delegate.finished_spans).to be_empty
        expect(logger).to have_received(:error).with(/malformed patch/)
      end
    end

    context "when a replacement attribute value is invalid" do
      let(:hook) do
        ->(spans:) { spans.each_key.to_h { |id| [id, { set: { "gen_ai.prompt" => Object.new } }] } }
      end

      it "omits the attribute instead of exporting the original value" do
        exporter.export([third_party_span])

        exported = delegate.finished_spans.first
        expect(exported.attributes).not_to have_key("gen_ai.prompt")
        expect(exported.attributes["gen_ai.system"]).to eq("openai")
      end

      it "logs the key without the value" do
        exporter.export([third_party_span])

        expect(logger).to have_received(:warn) do |message|
          expect(message).to include("gen_ai.prompt")
          expect(message).not_to include("ssn 123-45-6789")
        end
      end
    end

    context "with valid replacement value types" do
      let(:hook) do
        lambda do |spans:|
          spans.each_key.to_h do |id|
            [id, { set: {
              "string" => "ok", "int" => 1, "float" => 1.5, "bool" => true,
              "bools" => [true, false], "strings" => %w[a b], "empty" => []
            } }]
          end
        end
      end

      it "accepts scalars and homogeneous scalar arrays" do
        exporter.export([third_party_span])

        attributes = delegate.finished_spans.first.attributes
        expect(attributes).to include(
          "string" => "ok", "int" => 1, "float" => 1.5, "bool" => true,
          "bools" => [true, false], "strings" => %w[a b], "empty" => []
        )
        expect(logger).not_to have_received(:warn)
      end
    end

    context "with a heterogeneous array replacement" do
      let(:hook) do
        ->(spans:) { spans.each_key.to_h { |id| [id, { set: { "mixed" => ["a", 1] } }] } }
      end

      it "rejects the value and omits the attribute" do
        exporter.export([third_party_span])

        expect(delegate.finished_spans.first.attributes).not_to have_key("mixed")
        expect(logger).to have_received(:warn).with(/'mixed'/)
      end
    end

    context "with patches keyed by unknown identifiers" do
      let(:hook) { ->(**) { { "deadbeef:cafebabe" => { delete: ["x"] } } } }

      it "ignores them and exports the batch" do
        exporter.export(batch)

        expect(delegate.finished_spans.size).to eq(2)
      end
    end
  end

  describe "#force_flush and #shutdown" do
    it "delegates force_flush" do
      expect(delegate).to receive(:force_flush).with(timeout: 5)
      exporter.force_flush(timeout: 5)
    end

    it "delegates shutdown" do
      expect(delegate).to receive(:shutdown).with(timeout: 5)
      exporter.shutdown(timeout: 5)
    end
  end
end
