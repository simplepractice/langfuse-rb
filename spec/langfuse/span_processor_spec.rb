# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::SpanProcessor do
  let(:processor) { described_class.new }
  let(:tracer) { OpenTelemetry.tracer_provider.tracer("test") }

  before do
    Langfuse.configure do |config|
      config.public_key = "pk_test"
      config.secret_key = "sk_test"
    end
  end

  describe "#on_start" do
    it "sets propagated attributes on new spans" do
      span = nil

      Langfuse::Propagation.propagate_attributes(user_id: "user_123", session_id: "session_abc") do
        span = tracer.start_span("test-span")
        # Simulate what the span processor does
        parent_context = OpenTelemetry::Context.current
        processor.on_start(span, parent_context)
      end

      expect(span).not_to be_nil
      expect(span.recording?).to be true

      attrs = span.attributes
      expect(attrs["user.id"]).to eq("user_123")
      expect(attrs["session.id"]).to eq("session_abc")

      span.finish
    end

    it "does not set attributes on non-recording spans" do
      # Create a non-recording span
      span_context = OpenTelemetry::Trace::SpanContext.new(
        trace_id: OpenTelemetry::Trace.generate_trace_id,
        span_id: OpenTelemetry::Trace.generate_span_id,
        trace_flags: OpenTelemetry::Trace::TraceFlags::SAMPLED
      )
      non_recording_span = OpenTelemetry::Trace.non_recording_span(span_context)
      context = OpenTelemetry::Trace.context_with_span(non_recording_span)

      # Create a recording span but with non-recording parent context
      span = tracer.start_span("test-span")

      # Should not error even with non-recording span in context
      expect { processor.on_start(span, context) }.not_to raise_error

      span.finish
    end

    it "handles spans with no propagated attributes" do
      span = tracer.start_span("test-span")
      context = OpenTelemetry::Context.current

      # Should not error when no attributes are in context
      expect { processor.on_start(span, context) }.not_to raise_error

      span.finish
    end

    it "sets metadata attributes correctly" do
      span = nil

      Langfuse::Propagation.propagate_attributes(metadata: { environment: "production", region: "us-east" }) do
        span = tracer.start_span("test-span")
        parent_context = OpenTelemetry::Context.current
        processor.on_start(span, parent_context)
      end

      attrs = span.attributes
      expect(attrs["langfuse.trace.metadata.environment"]).to eq("production")
      expect(attrs["langfuse.trace.metadata.region"]).to eq("us-east")

      span.finish
    end

    it "sets tags correctly" do
      span = nil

      Langfuse::Propagation.propagate_attributes(tags: %w[production api-v2]) do
        span = tracer.start_span("test-span")
        parent_context = OpenTelemetry::Context.current
        processor.on_start(span, parent_context)
      end

      attrs = span.attributes
      tags_value = attrs["langfuse.trace.tags"]
      expect(tags_value).to be_a(String) # JSON serialized
      tags = JSON.parse(tags_value)
      expect(tags).to contain_exactly("production", "api-v2")

      span.finish
    end
  end

  describe "#on_finish" do
    it "does not error" do
      span = tracer.start_span("test-span")
      expect { processor.on_finish(span) }.not_to raise_error
      span.finish
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
