# frozen_string_literal: true

require "spec_helper"
require "opentelemetry/baggage"

RSpec.describe "Metadata encoding" do
  let(:metadata) do
    { string: "123", number: 5, boolean: false, array: [1, "two", nil], nested: { leaf: "value" }, null: nil }
  end
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }

  before do
    Langfuse.configure do |config|
      config.metadata_encoding = :json
      config.tracing_async = false
      config.span_exporter = exporter
    end
  end

  def decoded(span, prefix = "langfuse.trace.metadata")
    JSON.parse(span.otel_span.attributes.fetch(prefix))
  end

  it "defaults to legacy encoding and rejects unknown formats" do
    expect(Langfuse::Config.new.metadata_encoding).to eq(:legacy)
    expect { Langfuse.configuration.metadata_encoding = :automatic }
      .to raise_error(Langfuse::ConfigurationError, "metadata_encoding must be :legacy or :json")
  end

  it "uses the same JSON object format for observations, traces, experiments, and items" do
    attributes = Langfuse::OtelAttributes.create_observation_attributes("span", { metadata: metadata })
    attributes.merge!(Langfuse::OtelAttributes.create_trace_attributes({ metadata: metadata }))
    attributes.merge!(Langfuse::ExperimentAttributes.propagated(
                        experiment_id: "run", run_name: "test", item_id: "item", root_observation_id: "root",
                        experiment_metadata: metadata, item_metadata: metadata
                      ))

    %w[observation trace experiment experiment.item].each do |domain|
      prefix = "langfuse.#{domain}.metadata"
      expect(JSON.parse(attributes.fetch(prefix))).to eq(JSON.parse(metadata.to_json))
      expect(attributes.keys.grep(/^#{Regexp.escape(prefix)}\./)).to be_empty
    end
  end

  it "omits nil metadata and unserializable objects" do
    cyclic = []
    cyclic << cyclic
    expect(Langfuse::MetadataEncoding.attributes(nil, "metadata")).to eq({})
    expect(Langfuse::MetadataEncoding.attributes(cyclic, "metadata")).to eq({})
  end

  it "merges updates by top-level key and replaces nested values, including null" do
    Langfuse.observe("root", metadata: { retained: true, nested: { old: 1 } }) do |span|
      span.update(metadata: { nested: { new: 2 }, null: nil })
      span.update_trace(metadata: { retained: true })
      Langfuse.propagate_attributes(metadata: { added: false }) do
        expect(decoded(span)).to eq("retained" => true, "added" => false)
      end
      expect(decoded(span, "langfuse.observation.metadata"))
        .to eq("retained" => true, "nested" => { "new" => 2 }, "null" => nil)
    end
  end

  it "replaces invalid or non-object existing metadata without retaining it" do
    Langfuse.observe("root") do |span|
      ["invalid-json", '"old"', 5].each do |existing|
        span.otel_span.set_attribute("langfuse.observation.metadata", existing)
        span.update(metadata: { safe: true })
        expect(decoded(span, "langfuse.observation.metadata")).to eq("safe" => true)
      end
    end
  end

  it "snapshots propagated JSON values and scopes nested overrides without mutating caller data" do
    values = { nested: { array: [+"original"] }, null: nil, boolean: false }
    Langfuse.propagate_attributes(metadata: values) do
      values[:nested][:array][0].replace("changed")
      Langfuse.observe("parent") do |parent|
        expect(decoded(parent)).to eq("nested" => { "array" => ["original"] }, "null" => nil, "boolean" => false)
        Langfuse.propagate_attributes(metadata: { nested: [2] }) do
          Langfuse.observe("child") { |child| expect(decoded(child)["nested"]).to eq([2]) }
        end
        Langfuse.observe("sibling") do |sibling|
          expect(decoded(sibling)["nested"]).to eq("array" => ["original"])
        end
      end
    end
    Langfuse.observe("outside") { |span| expect(span.otel_span.attributes).not_to have_key("langfuse.trace.metadata") }
  end

  it "enforces encoded length and drops invalid JSON without dropping valid siblings" do
    cyclic = []
    cyclic << cyclic
    values = { exact: "a" * 198, long: "a" * 199, escaped: '"' * 100, invalid: Float::NAN, cyclic: cyclic }
    Langfuse.propagate_attributes(metadata: values.merge(ok: false)) do
      Langfuse.observe("root") do |span|
        expect(decoded(span)).to eq("exact" => "a" * 198, "ok" => false)
      end
    end
  end

  it "omits empty or fully rejected metadata without changing inherited values" do
    [{}, { oversized: "a" * 201 }, { invalid: Float::NAN }].each do |values|
      Langfuse.propagate_attributes(metadata: values, as_baggage: true) do
        Langfuse.observe("empty") do |span|
          expect(span.otel_span.attributes).not_to have_key("langfuse.trace.metadata")
          expect(OpenTelemetry::Baggage.values.keys.grep(/langfuse_metadata/)).to be_empty
        end
      end
      Langfuse.propagate_attributes(metadata: { retained: true }) do
        Langfuse.propagate_attributes(metadata: values) do
          Langfuse.observe("inherited") { |span| expect(decoded(span)).to eq("retained" => true) }
        end
      end
    end
  end

  it "merges concurrent metadata updates without losing independent keys" do
    read_started = Queue.new
    release_read = Queue.new
    Langfuse.observe("root", metadata: { seed: true }) do |span|
      allow(span.otel_span).to receive(:attributes).and_wrap_original do |read|
        snapshot = read.call
        if Thread.current[:hold_metadata_read]
          Thread.current[:hold_metadata_read] = false
          read_started << true
          release_read.pop
        end
        snapshot
      end
      first = Thread.new do
        Thread.current[:hold_metadata_read] = true
        span.update(metadata: { first: true })
      end
      read_started.pop
      second = Thread.new { span.update(metadata: { second: true }) }
      Thread.pass while second.alive? && second.status != "sleep"
      release_read << true
      [first, second].each(&:value)
      expect(decoded(span, "langfuse.observation.metadata"))
        .to eq("seed" => true, "first" => true, "second" => true)
    end
  end

  it "preserves legacy string limits and encodes newly accepted values with the legacy wire format" do
    Langfuse.configuration.metadata_encoding = :legacy
    Langfuse.propagate_attributes(metadata: metadata.merge(long: "a" * 200)) do
      Langfuse.observe("root") do |span|
        expect(span.otel_span.attributes).to include(
          "langfuse.trace.metadata.string" => "123", "langfuse.trace.metadata.number" => "5",
          "langfuse.trace.metadata.boolean" => "false", "langfuse.trace.metadata.array" => '[1,"two",null]',
          "langfuse.trace.metadata.nested.leaf" => "value", "langfuse.trace.metadata.long" => "a" * 200
        )
        expect(span.otel_span.attributes).not_to have_key("langfuse.trace.metadata.null")
      end
    end
  end

  it "round trips JSON baggage into another context and merges local metadata" do
    baggage = nil
    Langfuse.propagate_attributes(metadata: metadata, as_baggage: true) do
      baggage = OpenTelemetry::Baggage.values
      expect(baggage.fetch("langfuse_metadata_string")).to eq('"123"')
    end
    remote = baggage.reduce(OpenTelemetry::Context.empty) do |context, (key, value)|
      OpenTelemetry::Baggage.set_value(key, value, context: context)
    end
    OpenTelemetry::Context.with_current(remote) do
      Langfuse.observe("receiver") do |span|
        expect(decoded(span)).to eq(JSON.parse(metadata.to_json))
        Langfuse.propagate_attributes(metadata: { number: 9 }) do
          expect(decoded(span)["number"]).to eq(9)
          Langfuse.observe("child") do |child|
            expect(decoded(child)).to eq(JSON.parse(metadata.merge(number: 9).to_json))
          end
        end
      end
    end
  end

  it "limits legacy metadata after flattening while retaining valid sibling leaves" do
    Langfuse.configuration.metadata_encoding = :legacy
    values = { nested: { string: "a" * 200, oversized: "b" * 201,
                         array: ["c" * 196], oversized_array: ["d" * 197] } }
    expected = { "langfuse.trace.metadata.nested.string" => "a" * 200,
                 "langfuse.trace.metadata.nested.array" => JSON.generate(["c" * 196]) }

    Langfuse.propagate_attributes(metadata: values, as_baggage: true) do
      Langfuse.observe("root") do |span|
        expect(span.otel_span.attributes.select { |key, _| key.include?("metadata") }).to eq(expected)
        baggage = OpenTelemetry::Baggage.values.select { |key, _| key.start_with?("langfuse_metadata_") }
        expect(baggage).to eq("langfuse_metadata_nested.string" => "a" * 200,
                              "langfuse_metadata_nested.array" => JSON.generate(["c" * 196]))
      end
    end
  end

  it "accepts unquoted legacy baggage strings when JSON parsing fails" do
    context = OpenTelemetry::Baggage.set_value("langfuse_metadata_region", "us-east")
    OpenTelemetry::Context.with_current(context) do
      Langfuse.observe("receiver") { |span| expect(decoded(span)).to eq("region" => "us-east") }
    end
  end

  it "uses identical legacy metadata on current, child, and baggage-only receiver spans" do
    Langfuse.configuration.metadata_encoding = :legacy
    baggage = nil
    expected = { "langfuse.trace.metadata.object.enabled" => "false" }
    Langfuse.observe("current") do |span|
      Langfuse.propagate_attributes(metadata: { object: { enabled: false } }, as_baggage: true) do
        baggage = OpenTelemetry::Baggage.values
        expect(baggage["langfuse_metadata_object.enabled"]).to eq("false")
        expect(span.otel_span.attributes.select { |key, _| key.include?("metadata") }).to eq(expected)
        Langfuse.observe("child") do |child|
          expect(child.otel_span.attributes.select { |key, _| key.include?("metadata") }).to eq(expected)
        end
      end
    end
    remote = baggage.reduce(OpenTelemetry::Context.empty) do |context, (key, value)|
      OpenTelemetry::Baggage.set_value(key, value, context: context)
    end
    OpenTelemetry::Context.with_current(remote) do
      Langfuse.observe("receiver") do |span|
        expect(span.otel_span.attributes.select { |key, _| key.include?("metadata") }).to eq(expected)
      end
    end
  end

  it "applies creation masking to metadata objects before JSON encoding" do
    mask = ->(data:) { data.is_a?(Hash) ? data.merge(secret: "redacted") : data }
    Langfuse.configuration.mask = mask
    Langfuse.observe("root", metadata: { secret: "observation" }) do |span|
      span.update_trace(metadata: { secret: "trace" })
      expect(decoded(span, "langfuse.observation.metadata")["secret"]).to eq("redacted")
      expect(decoded(span)["secret"]).to eq("redacted")
    end
    attributes = Langfuse::ExperimentAttributes.propagated(
      experiment_id: "run", run_name: "test", item_id: "item", root_observation_id: "root",
      experiment_metadata: { secret: "run" }, item_metadata: { secret: "item" }, mask: mask
    )
    expect(JSON.parse(attributes.fetch("langfuse.experiment.metadata"))).to eq("secret" => "redacted")
    expect(JSON.parse(attributes.fetch("langfuse.experiment.item.metadata"))).to eq("secret" => "redacted")
  end

  it "fails closed when creation masking raises during an update" do
    Langfuse.observe("root", metadata: { secret: "original" }) do |span|
      Langfuse.configuration.mask = ->(data:) { raise "failed for #{data.class}" }
      span.update(metadata: { secret: "replacement" })
      expect(decoded(span, "langfuse.observation.metadata")).to eq(Langfuse::Masking::FALLBACK)
    end
  end

  it "lets export hooks decode, replace, and delete metadata before the custom exporter sees it" do
    original = nil
    Langfuse.configuration.mask_otel_spans = lambda do |params:|
      patches = params.spans.to_h do |identifier, span|
        values = JSON.parse(span.attributes.fetch("langfuse.trace.metadata"))
        values["secret"] = "redacted"
        [identifier, Langfuse::OtelSpanPatch.new(
          set_attributes: { "langfuse.trace.metadata" => JSON.generate(values) },
          delete_attributes: ["langfuse.observation.metadata"]
        )]
      end
      Langfuse::MaskOtelSpansResult.new(span_patches: patches)
    end
    Langfuse.propagate_attributes(metadata: { secret: "original", boolean: false }) do
      Langfuse.observe("root", metadata: { secret: "delete" }) { |span| original = span }
    end
    Langfuse.force_flush
    attributes = exporter.finished_spans.fetch(0).attributes
    expect(JSON.parse(attributes.fetch("langfuse.trace.metadata"))).to eq("secret" => "redacted", "boolean" => false)
    expect(attributes).not_to have_key("langfuse.observation.metadata")
    expect(decoded(original)["secret"]).to eq("original")
  end
end
