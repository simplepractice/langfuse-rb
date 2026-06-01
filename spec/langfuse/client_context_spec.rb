# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe "Langfuse active client context" do
  def build_client(suffix)
    config = Langfuse::Config.new do |c|
      c.public_key = "pk_#{suffix}"
      c.secret_key = "sk_#{suffix}"
      c.base_url = "https://cloud.langfuse.com"
      c.tracing_async = false
      c.flush_interval = 0
      c.logger = Logger.new(StringIO.new)
    end
    client = Langfuse::Client.new(config)
    constructed_clients << client
    client
  end

  def score_client(client)
    client.instance_variable_get(:@score_client)
  end

  def constructed_clients
    @constructed_clients ||= []
  end

  let(:client_a) { build_client("a") }
  let(:client_b) { build_client("b") }

  after do
    constructed_clients.each(&:shutdown)
  rescue StandardError
    nil
  end

  it "routes module-level active trace scores through the active observation owner" do
    expect(score_client(client_a)).to receive(:score_active_trace).with(
      name: "owner-a", value: 1, comment: nil, metadata: nil, data_type: :numeric
    )
    expect(score_client(client_b)).to receive(:score_active_trace).with(
      name: "owner-b", value: 2, comment: nil, metadata: nil, data_type: :numeric
    )

    client_a.observe("trace-a") { Langfuse.score_active_trace(name: "owner-a", value: 1) }
    client_b.observe("trace-b") { Langfuse.score_active_trace(name: "owner-b", value: 2) }
  end

  it "routes module-level active observation scores through the active observation owner" do
    expect(score_client(client_a)).to receive(:score_active_observation).with(
      name: "observation-owner", value: 0.9, comment: nil, metadata: nil, data_type: :numeric
    )

    client_a.observe("observation-a") do
      Langfuse.score_active_observation(name: "observation-owner", value: 0.9)
    end
  end

  it "raises when an explicit client scores another client's active observation" do
    expect do
      client_b.observe("trace-b") do
        client_a.score_active_trace(name: "wrong-owner", value: 1)
      end
    end.to raise_error(ArgumentError, /different client/)
  end

  it "allows explicit clients to score raw OpenTelemetry active spans" do
    tracer = OpenTelemetry.tracer_provider.tracer("raw")
    span = tracer.start_span("raw-span")

    expect(score_client(client_a)).to receive(:score_active_trace).with(
      name: "raw-owner", value: 1, comment: nil, metadata: nil, data_type: :numeric
    )

    OpenTelemetry::Context.with_current(OpenTelemetry::Trace.context_with_span(span)) do
      client_a.score_active_trace(name: "raw-owner", value: 1)
    end
  ensure
    span&.finish
  end

  it "preserves singleton raw OpenTelemetry fallback with a deprecation warning" do
    tracer = OpenTelemetry.tracer_provider.tracer("raw")
    span = tracer.start_span("raw-span")
    singleton_score_client = score_client(Langfuse.client)

    expect(Langfuse.configuration.logger).to receive(:warn).with(/raw OpenTelemetry fallback/)
    expect(singleton_score_client).to receive(:score_active_trace).with(
      name: "singleton-raw", value: 1, comment: nil, metadata: nil, data_type: :numeric
    )

    OpenTelemetry::Context.with_current(OpenTelemetry::Trace.context_with_span(span)) do
      Langfuse.score_active_trace(name: "singleton-raw", value: 1)
    end
  ensure
    span&.finish
  end
end
