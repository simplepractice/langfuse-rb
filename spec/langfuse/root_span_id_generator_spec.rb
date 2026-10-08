# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe Langfuse::RootSpanIdGenerator do
  subject(:id_generator) { described_class.new }

  let(:trace_id) { ["a" * 32].pack("H*") }
  let(:other_trace_id) { ["b" * 32].pack("H*") }

  it "scopes the requested ID to this generator and this block" do
    other_generator = described_class.new

    id_generator.with_trace_id(trace_id) do
      expect(id_generator.generate_trace_id).to eq(trace_id)
      expect(other_generator.generate_trace_id).not_to eq(trace_id)
    end

    expect(id_generator.generate_trace_id).not_to eq(trace_id)
  end

  it "clears the ambient parent and root claim while preserving other context values" do
    parent = OpenTelemetry::Trace.non_recording_span(Langfuse::TraceId.send(:to_span_context, "c" * 32))
    context = OpenTelemetry::Trace.context_with_span(parent)
    user_key = Langfuse::Propagation::CONTEXT_KEYS.fetch("user_id")
    claim_key = Langfuse::Propagation::LANGFUSE_TRACE_ID_BAGGAGE_KEY
    context = context.set_value(user_key, "synthetic-user")
    context = OpenTelemetry::Baggage.build(context: context) do |baggage|
      baggage.set_value(claim_key, "c" * 32)
      baggage.set_value("other", "preserved")
    end

    OpenTelemetry::Context.with_current(context) do
      id_generator.with_trace_id(trace_id) do |root_context|
        expect(OpenTelemetry::Trace.current_span(root_context).context).not_to be_valid
        expect(root_context.value(user_key)).to eq("synthetic-user")
        expect(OpenTelemetry::Baggage.values(context: root_context)).to eq("other" => "preserved")
      end
    end
  end

  it "restores the caller's context and clears the requested ID when span creation raises" do
    original_context = OpenTelemetry::Context.current

    expect do
      id_generator.with_trace_id(trace_id) { raise "span creation failed" }
    end.to raise_error(RuntimeError, "span creation failed")

    expect(OpenTelemetry::Context.current).to equal(original_context)
    expect(id_generator.generate_trace_id).not_to eq(trace_id)
  end

  it "keeps interleaved fibers independent" do
    fibers = [trace_id, other_trace_id].map do |id|
      Fiber.new do
        id_generator.with_trace_id(id) do
          Fiber.yield
          id_generator.generate_trace_id
        end
      end
    end

    fibers.each(&:resume)
    expect(fibers.map(&:resume)).to eq([trace_id, other_trace_id])
    expect([trace_id, other_trace_id]).not_to include(id_generator.generate_trace_id)
  end

  it "keeps overlapping threads independent" do
    ready = Queue.new
    release = Queue.new
    threads = [trace_id, other_trace_id].map do |id|
      Thread.new do
        id_generator.with_trace_id(id) do
          ready << true
          release.pop
          id_generator.generate_trace_id
        end
      end
    end

    Timeout.timeout(2) { 2.times { ready.pop } }
    expect([trace_id, other_trace_id]).not_to include(id_generator.generate_trace_id)
    2.times { release << true }
    expect(threads.map(&:value)).to eq([trace_id, other_trace_id])
  ensure
    threads&.each { release << true }
    threads&.each(&:join)
  end
end
