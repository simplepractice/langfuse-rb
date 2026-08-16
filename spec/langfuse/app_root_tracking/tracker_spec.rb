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

    tracker.remember(span, trace_claimed: true, app_root_eligible: true)

    ready_spans = tracker.finish(span, exportable: true)

    expect(ready_spans.map(&:span)).to eq([span])
    expect(ready_spans.map(&:app_root)).to eq([false])
  end

  it "releases a finished span without children" do
    span_id = OpenTelemetry::Trace.generate_span_id
    span = build_span(span_id: span_id)
    tracker.remember(span, trace_claimed: false, app_root_eligible: true)

    tracker.finish(span, exportable: true)

    expect(tracker).to be_empty
  end

  it "does not classify a span that has no tracking state" do
    span = build_span(span_id: OpenTelemetry::Trace.generate_span_id)

    expect(tracker.finish(span, exportable: true)).to be_empty
  end

  it "retains a finished parent until its child finishes" do
    parent_id = OpenTelemetry::Trace.generate_span_id
    child_id = OpenTelemetry::Trace.generate_span_id
    parent = build_span(span_id: parent_id)
    child = build_span(span_id: child_id, parent_span_id: parent_id)
    tracker.remember(parent, trace_claimed: false, app_root_eligible: true)
    tracker.remember(child, trace_claimed: false, app_root_eligible: true)

    tracker.finish(parent, exportable: true)

    expect(tracker).not_to be_empty

    tracker.finish(child, exportable: true)

    expect(tracker).to be_empty
  end

  it "defers a finished child until its parent export decision is final" do
    parent_id = OpenTelemetry::Trace.generate_span_id
    child_id = OpenTelemetry::Trace.generate_span_id
    parent = build_span(span_id: parent_id)
    child = build_span(span_id: child_id, parent_span_id: parent_id)
    tracker.remember(parent, trace_claimed: false, app_root_eligible: true)
    tracker.remember(child, trace_claimed: false, app_root_eligible: true)

    expect(tracker.finish(child, exportable: true)).to be_empty

    ready_spans = tracker.finish(parent, exportable: true)

    expect(ready_spans.map(&:span)).to contain_exactly(parent, child)
    expect(ready_spans.to_h { |ready_span| [ready_span.span, ready_span.app_root] }).to eq(
      parent => true,
      child => false
    )
  end

  it "does not mark an ineligible span as an application root" do
    span = build_span(span_id: OpenTelemetry::Trace.generate_span_id)
    tracker.remember(span, trace_claimed: false, app_root_eligible: false)

    ready_span = tracker.finish(span, exportable: true).fetch(0)

    expect(ready_span.app_root).to be(false)
  end
end
