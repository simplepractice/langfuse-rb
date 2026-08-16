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
    build_span_data(name: "chat gpt-4o", scope_name: "ruby-openai",
                    attributes: { "gen_ai.prompt" => +"ssn 123-45-6789", "gen_ai.system" => +"openai" })
  end

  def batch
    [langfuse_span, third_party_span]
  end

  def build_span_data(name:, scope_name:, attributes: {}, parent_span_id: OpenTelemetry::Trace::INVALID_SPAN_ID,
                      span_id: OpenTelemetry::Trace.generate_span_id,
                      trace_id: OpenTelemetry::Trace.generate_trace_id)
    OpenTelemetry::SDK::Trace::SpanData.new(
      name, :internal, OpenTelemetry::Trace::Status.ok, parent_span_id,
      attributes.size, 0, 0, 1_000, 2_000, attributes, nil, nil,
      OpenTelemetry::SDK::Resources::Resource.create({ "service.name" => "test-app" }),
      OpenTelemetry::SDK::InstrumentationScope.new(scope_name, "1.0.0"),
      span_id, trace_id, OpenTelemetry::Trace::TraceFlags::DEFAULT,
      OpenTelemetry::Trace::Tracestate::DEFAULT, false
    )
  end

  def identifier(span)
    Langfuse::OtelSpanIdentifier.new(trace_id: span.hex_trace_id, span_id: span.hex_span_id)
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
      let(:hook) { ->(params:) { seen << params } }

      it "uses explicit value objects" do
        exporter.export(batch)

        expect(seen.first).to be_a(Langfuse::MaskOtelSpansParams)
        expect(seen.first.spans.keys).to all(be_a(Langfuse::OtelSpanIdentifier))
        expect(seen.first.spans.values).to all(be_a(Langfuse::OtelSpanData))
        expect(seen.first.spans.keys.first.trace_id).to be_frozen
        expect(seen.first.spans.keys.first.span_id).to be_frozen
      end

      it "exposes the complete supported span snapshot" do
        parent_span_id = OpenTelemetry::Trace.generate_span_id
        span = build_span_data(name: "child", scope_name: "ruby-openai", parent_span_id: parent_span_id,
                               attributes: { "gen_ai.prompt" => "secret" })

        exporter.export([span])

        snapshot = seen.first.spans.fetch(identifier(span))
        expect(snapshot).to have_attributes(
          trace_id: span.hex_trace_id,
          span_id: span.hex_span_id,
          parent_span_id: parent_span_id.unpack1("H*"),
          name: "child",
          instrumentation_scope_name: "ruby-openai",
          instrumentation_scope_version: "1.0.0"
        )
        expect(snapshot.attributes).to eq("gen_ai.prompt" => "secret")
        expect(snapshot.resource_attributes).to include("service.name" => "test-app")
      end

      it "gives the hook a frozen mapping with frozen copied values" do
        original = [+"tag-one", +"tag-two"]
        span = build_span_data(name: +"mutable-name", scope_name: +"mutable-scope",
                               attributes: { "gen_ai.tags" => original })

        exporter.export([span])

        snapshot = seen.first.spans.fetch(identifier(span))
        expect(seen.first.spans).to be_frozen
        expect(snapshot.name).to be_frozen
        expect(snapshot.instrumentation_scope_name).to be_frozen
        expect(snapshot.attributes).to be_frozen
        expect(snapshot.attributes["gen_ai.tags"]).to be_frozen
        expect(snapshot.attributes["gen_ai.tags"].first).to be_frozen
        expect(snapshot.attributes["gen_ai.tags"].first).not_to equal(original.first)
        expect(original.first).not_to be_frozen
      end

      it "reuses already-frozen attribute values instead of copying them" do
        frozen_payload = "already frozen prompt"
        span = build_span_data(name: "frozen", scope_name: "ruby-openai",
                               attributes: { "gen_ai.prompt" => frozen_payload })

        exporter.export([span])

        snapshot = seen.first.spans.fetch(identifier(span))
        expect(snapshot.attributes["gen_ai.prompt"]).to equal(frozen_payload)
      end
    end

    context "with sparse patches" do
      let(:hook) do
        lambda do |params:|
          target = params.spans.find { |_identifier, span| span.instrumentation_scope_name == "ruby-openai" }.first
          Langfuse::MaskOtelSpansResult.new(
            span_patches: {
              target => Langfuse::OtelSpanPatch.new(
                delete_attributes: ["gen_ai.prompt"],
                set_attributes: { "gen_ai.prompt.masked" => true }
              )
            }
          )
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

    it "applies deletes before sets" do
      replacement_hook = lambda do |params:|
        patches = params.spans.to_h do |span_identifier, _span|
          [span_identifier, Langfuse::OtelSpanPatch.new(
            delete_attributes: ["gen_ai.prompt"], set_attributes: { "gen_ai.prompt" => "<redacted>" }
          )]
        end
        Langfuse::MaskOtelSpansResult.new(span_patches: patches)
      end
      replacement_exporter = described_class.new(delegate: delegate, hook: replacement_hook, logger: logger)

      replacement_exporter.export([third_party_span])

      expect(delegate.finished_spans.first.attributes["gen_ai.prompt"]).to eq("<redacted>")
    end

    context "when the hook raises" do
      let(:hook) { ->(**) { raise "leaky ssn 123-45-6789" } }

      it "consumes and drops the batch without reporting a transport failure" do
        result = exporter.export(batch)

        expect(result).to eq(OpenTelemetry::SDK::Trace::Export::SUCCESS)
        expect(delegate.finished_spans).to be_empty
      end

      it "logs only the exception class" do
        exporter.export(batch)

        expect(logger).to have_received(:error) do |message|
          expect(message).to include("mask_otel_spans raised RuntimeError")
          expect(message).not_to include("leaky ssn")
        end
      end

      it "logs the number of dropped spans" do
        exporter.export(batch)

        expect(logger).to have_received(:error).with(/dropping the Langfuse export batch of 2 spans/)
      end
    end

    it "does not blame the hook when building the snapshot fails" do
      broken_resource = instance_double(OpenTelemetry::SDK::Resources::Resource)
      allow(broken_resource).to receive(:attribute_enumerator).and_raise("resource exploded")
      broken = third_party_span.dup
      broken.resource = broken_resource
      called = false
      snapshot_exporter = described_class.new(
        delegate: delegate, hook: ->(**) { called = true }, logger: logger
      )

      expect { snapshot_exporter.export([broken]) }.to raise_error("resource exploded")
      expect(called).to be(false)
      expect(logger).not_to have_received(:error).with(/mask_otel_spans raised/)
    end

    it "drops the batch when the hook returns an invalid result" do
      invalid_exporter = described_class.new(delegate: delegate, hook: ->(**) { { span_patches: {} } }, logger: logger)

      result = invalid_exporter.export(batch)

      expect(result).to eq(OpenTelemetry::SDK::Trace::Export::SUCCESS)
      expect(delegate.finished_spans).to be_empty
      expect(logger).to have_received(:error).with(/invalid result/)
    end

    it "drops the batch when span_patches is not a Hash" do
      invalid_hook = ->(**) { Langfuse::MaskOtelSpansResult.new(span_patches: []) }
      invalid_exporter = described_class.new(delegate: delegate, hook: invalid_hook, logger: logger)

      expect(invalid_exporter.export(batch)).to eq(OpenTelemetry::SDK::Trace::Export::SUCCESS)
      expect(delegate.finished_spans).to be_empty
    end

    it "leaves a span unchanged when its patch is nil" do
      nil_patch_hook = lambda do |params:|
        Langfuse::MaskOtelSpansResult.new(span_patches: { params.spans.keys.first => nil })
      end
      nil_patch_exporter = described_class.new(delegate: delegate, hook: nil_patch_hook, logger: logger)

      nil_patch_exporter.export([third_party_span])

      expect(delegate.finished_spans.first).to equal(third_party_span)
    end

    it "drops only the span with an invalid patch object" do
      invalid_patch_hook = lambda do |params:|
        first, second = params.spans.keys
        Langfuse::MaskOtelSpansResult.new(
          span_patches: { first => { set_attributes: {} }, second => Langfuse::OtelSpanPatch.new }
        )
      end
      invalid_exporter = described_class.new(delegate: delegate, hook: invalid_patch_hook, logger: logger)

      invalid_exporter.export(batch)

      expect(delegate.finished_spans.map(&:name)).to eq(["chat gpt-4o"])
      expect(logger).to have_received(:error).with(/invalid span patch/)
    end

    it "drops only the span with invalid patch containers" do
      invalid_patch_hook = lambda do |params:|
        patch = Langfuse::OtelSpanPatch.new(set_attributes: [], delete_attributes: "secret")
        Langfuse::MaskOtelSpansResult.new(span_patches: { params.spans.keys.first => patch })
      end
      invalid_exporter = described_class.new(delegate: delegate, hook: invalid_patch_hook, logger: logger)

      invalid_exporter.export([third_party_span])

      expect(delegate.finished_spans).to be_empty
      expect(logger).to have_received(:error).with(/invalid span patch/)
    end

    it "identifies the dropped span by trace and span ID" do
      invalid_patch_hook = lambda do |params:|
        Langfuse::MaskOtelSpansResult.new(span_patches: { params.spans.keys.first => Object.new })
      end
      invalid_exporter = described_class.new(delegate: delegate, hook: invalid_patch_hook, logger: logger)

      invalid_exporter.export([third_party_span])

      expect(logger).to have_received(:error).with(
        /trace_id=#{third_party_span.hex_trace_id} span_id=#{third_party_span.hex_span_id}/
      )
    end

    it "ignores invalid attribute keys without dropping valid patch entries" do
      invalid_keys_hook = lambda do |params:|
        patch = Langfuse::OtelSpanPatch.new(
          delete_attributes: [nil, "gen_ai.prompt"],
          set_attributes: { nil => "ignored", "masking.applied" => true }
        )
        Langfuse::MaskOtelSpansResult.new(span_patches: { params.spans.keys.first => patch })
      end
      invalid_keys_exporter = described_class.new(delegate: delegate, hook: invalid_keys_hook, logger: logger)

      invalid_keys_exporter.export([third_party_span])

      expect(delegate.finished_spans.first.attributes).to eq(
        "gen_ai.system" => "openai", "masking.applied" => true
      )
      expect(logger).to have_received(:warn).twice
    end

    context "when a replacement attribute value is invalid" do
      let(:hook) do
        lambda do |params:|
          patch = Langfuse::OtelSpanPatch.new(set_attributes: { "gen_ai.prompt" => Object.new })
          Langfuse::MaskOtelSpansResult.new(span_patches: { params.spans.keys.first => patch })
        end
      end

      it "omits the attribute instead of exporting the original value" do
        exporter.export([third_party_span])

        expect(delegate.finished_spans.first.attributes).to eq("gen_ai.system" => "openai")
      end

      it "logs the key without the original value" do
        exporter.export([third_party_span])

        expect(logger).to have_received(:warn) do |message|
          expect(message).to include("gen_ai.prompt")
          expect(message).not_to include("ssn 123-45-6789")
        end
      end
    end

    it "accepts OpenTelemetry scalar and homogeneous array values" do
      valid_values = {
        "string" => "ok", "int" => 1, "float" => 1.5, "bool" => true,
        "bools" => [true, false], "numbers" => [1, 2.5], "strings" => %w[a b], "empty" => []
      }
      valid_hook = lambda do |params:|
        patch = Langfuse::OtelSpanPatch.new(set_attributes: valid_values)
        Langfuse::MaskOtelSpansResult.new(span_patches: { params.spans.keys.first => patch })
      end
      valid_exporter = described_class.new(delegate: delegate, hook: valid_hook, logger: logger)

      valid_exporter.export([third_party_span])

      expect(delegate.finished_spans.first.attributes).to include(valid_values)
      expect(delegate.finished_spans.first.total_recorded_attributes).to be >= valid_values.size
      expect(logger).not_to have_received(:warn)
    end

    it "copies mutable replacement values" do
      replacement = +"masked"
      copy_hook = lambda do |params:|
        patch = Langfuse::OtelSpanPatch.new(set_attributes: { "gen_ai.prompt" => replacement })
        Langfuse::MaskOtelSpansResult.new(span_patches: { params.spans.keys.first => patch })
      end
      copy_exporter = described_class.new(delegate: delegate, hook: copy_hook, logger: logger)

      copy_exporter.export([third_party_span])

      exported_value = delegate.finished_spans.first.attributes["gen_ai.prompt"]
      expect(exported_value).to eq("masked")
      expect(exported_value).to be_frozen
      expect(exported_value).not_to equal(replacement)
    end

    it "deletes a heterogeneous array replacement" do
      invalid_value_hook = lambda do |params:|
        patch = Langfuse::OtelSpanPatch.new(set_attributes: { "mixed" => ["a", 1] })
        Langfuse::MaskOtelSpansResult.new(span_patches: { params.spans.keys.first => patch })
      end
      invalid_exporter = described_class.new(delegate: delegate, hook: invalid_value_hook, logger: logger)

      invalid_exporter.export([third_party_span])

      expect(delegate.finished_spans.first.attributes).not_to have_key("mixed")
    end

    it "drops the batch when a patch uses an unknown identifier" do
      unknown_identifier = Langfuse::OtelSpanIdentifier.new(trace_id: "1" * 32, span_id: "2" * 16)
      unknown_hook = lambda do |**|
        Langfuse::MaskOtelSpansResult.new(
          span_patches: { unknown_identifier => Langfuse::OtelSpanPatch.new(delete_attributes: ["secret"]) }
        )
      end
      unknown_exporter = described_class.new(delegate: delegate, hook: unknown_hook, logger: logger)

      expect(unknown_exporter.export(batch)).to eq(OpenTelemetry::SDK::Trace::Export::SUCCESS)
      expect(delegate.finished_spans).to be_empty
      expect(logger).to have_received(:error).with(/unknown span identifier/)
    end

    it "keeps the last span when identifiers are duplicated" do
      duplicate = third_party_span.dup
      duplicate.name = "duplicate-last"

      exporter.export([third_party_span, langfuse_span, duplicate])

      expect(delegate.finished_spans.map(&:name)).to eq(%w[langfuse-span duplicate-last])
    end

    it "drops invalid-context spans without dropping the rest of the batch" do
      invalid = third_party_span.dup
      invalid.trace_id = OpenTelemetry::Trace::INVALID_TRACE_ID

      exporter.export([invalid, langfuse_span])

      expect(delegate.finished_spans.map(&:name)).to eq(["langfuse-span"])
      expect(logger).to have_received(:warn).with(/invalid span context \(name=chat gpt-4o\)/)
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
