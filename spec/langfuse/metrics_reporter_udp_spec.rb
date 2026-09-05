# frozen_string_literal: true

require "spec_helper"
require "io/wait"
require "socket"

module MetricsReporterUdpTestSupport
  class BufferedReporter
    attr_reader :shutdown_called

    def initialize(host:, port:)
      @destination = [host, port]
      @socket = UDPSocket.new
      @buffer = []
      @mutex = Mutex.new
      @shutdown_called = false
    end

    def add_to_counter(metric, increment: 1, labels: {})
      append(metric_line(metric, increment, "c", labels))
    end

    def record_value(metric, value:, labels: {})
      append(metric_line(metric, value, "g", labels))
    end

    def observe_value(metric, value:, labels: {})
      append(metric_line(metric, value, "g", labels))
    end

    def flush
      payload = @mutex.synchronize { @buffer.join("\n") }
      @socket.send(payload, 0, *@destination)
    end

    def shutdown
      @shutdown_called = true
      raise "Langfuse must not shut down an application-owned reporter"
    end

    def close
      @socket.close
    end

    private

    def append(metric)
      @mutex.synchronize { @buffer << metric }
    end

    def metric_line(metric, value, type, labels)
      tags = labels.map { |key, label| "#{key}:#{label}" }
      suffix = tags.empty? ? "" : "|##{tags.join(',')}"
      "#{metric}:#{value}|#{type}#{suffix}"
    end
  end
end

RSpec.describe "application-owned metrics reporter UDP lifecycle" do
  let(:receiver) do
    UDPSocket.new.tap { |socket| socket.bind("127.0.0.1", 0) }
  end
  let(:reporter) do
    MetricsReporterUdpTestSupport::BufferedReporter.new(
      host: "127.0.0.1",
      port: receiver.addr[1]
    )
  end

  after do
    reporter.close
    receiver.close
  end

  it "delivers batch and OTLP metrics when the application flushes after Langfuse shutdown" do
    stub_request(:post, "https://api.langfuse.test/api/public/otel/v1/traces")
      .to_return(status: 400, body: "")
    Langfuse.configure do |config|
      config.public_key = "pk_test"
      config.secret_key = "sk_test"
      config.base_url = "https://api.langfuse.test"
      config.tracing_async = false
      config.metrics_reporter = reporter
    end

    Langfuse.observe("udp-proof").end
    Langfuse.shutdown
    reporter.add_to_counter("application.after_shutdown")
    reporter.flush

    expect(reporter.shutdown_called).to be(false)
    expect(receiver.wait_readable(1)).not_to be_nil
    payload = receiver.recvfrom_nonblock(65_535).first
    expect(payload).to include("otel.bsp.export.failure")
    expect(payload).to include("otel.bsp.dropped_spans")
    expect(payload).to include("otel.otlp_exporter.failure")
    expect(payload).to include("otel.otlp_exporter.message.compressed_size")
    expect(payload).to include("application.after_shutdown")
  end
end
