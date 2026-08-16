# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::AppRootTracking::Tracker do
  subject(:tracker) { described_class.new }

  let(:invalid_span_id) { OpenTelemetry::Trace::INVALID_SPAN_ID }

  def build_span(span_id:, parent_span_id: invalid_span_id)
    context = instance_double(OpenTelemetry::Trace::SpanContext, span_id: span_id)
    instance_double(
      OpenTelemetry::SDK::Trace::Span,
      context: context,
      parent_span_id: parent_span_id
    )
  end

  it "returns the remembered parent and trace claim" do
    span_id = OpenTelemetry::Trace.generate_span_id
    span = build_span(span_id: span_id)

    tracker.remember(span, trace_claimed: true)

    expect(tracker.parent_span_for(span_id)).to be(span)
    expect(tracker.trace_claimed?(span_id)).to be(true)
  end

  it "releases a finished span without children" do
    span_id = OpenTelemetry::Trace.generate_span_id
    tracker.remember(build_span(span_id: span_id), trace_claimed: false)

    tracker.finish(span_id)

    expect(tracker).to be_empty
  end

  it "retains a finished parent until its child finishes" do
    parent_id = OpenTelemetry::Trace.generate_span_id
    child_id = OpenTelemetry::Trace.generate_span_id
    parent = build_span(span_id: parent_id)
    child = build_span(span_id: child_id, parent_span_id: parent_id)
    tracker.remember(parent, trace_claimed: false)
    tracker.remember(child, trace_claimed: false)

    tracker.finish(parent_id)

    expect(tracker.parent_span_for(parent_id)).to be(parent)

    tracker.finish(child_id)

    expect(tracker).to be_empty
  end
end
