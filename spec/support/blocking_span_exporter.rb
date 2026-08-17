# frozen_string_literal: true

require "timeout"

module MetricsTestSupport
  class BlockingSpanExporter < OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter
    def initialize
      super
      @first_export_started = Queue.new
      @release_first_export = Queue.new
      @first_export = true
    end

    def export(spans, timeout: nil)
      # BatchSpanProcessor serializes exporter calls.
      if @first_export
        @first_export = false
        @first_export_started << true
        @release_first_export.pop
      end
      super
    end

    def wait_until_blocked(timeout: 2)
      Timeout.timeout(timeout) { @first_export_started.pop }
    end

    def release
      @release_first_export << true
    end
  end
end
