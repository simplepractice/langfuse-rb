# frozen_string_literal: true

require "concurrent/atomic/atomic_boolean"

module Langfuse
  # Protects trace processing from failures in an application-owned metrics reporter.
  #
  # @api private
  class ResilientMetricsReporter
    def self.wrap(reporter, logger:)
      return if reporter.nil?

      new(reporter, logger: logger)
    end

    def initialize(reporter, logger:)
      @reporter = reporter
      @logger = logger
      @warning_emitted = Concurrent::AtomicBoolean.new(false)
    end

    def add_to_counter(metric, increment: 1, labels: {})
      safely(:add_to_counter) do
        @reporter.add_to_counter(metric, increment: increment, labels: labels)
      end
    end

    def record_value(metric, value:, labels: {})
      safely(:record_value) do
        @reporter.record_value(metric, value: value, labels: labels)
      end
    end

    def observe_value(metric, value:, labels: {})
      safely(:observe_value) do
        @reporter.observe_value(metric, value: value, labels: labels)
      end
    end

    private

    def safely(method_name)
      yield
    rescue StandardError => e
      warn_once(method_name, e.class)
      nil
    end

    def warn_once(method_name, error_class)
      return unless @warning_emitted.make_true

      @logger.warn(
        "Langfuse metrics_reporter ##{method_name} failed with #{error_class}; " \
        "future reporter failures will be suppressed"
      )
    rescue StandardError
      nil
    end
  end
end
