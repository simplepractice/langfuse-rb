# frozen_string_literal: true

RSpec.describe Langfuse::Config do
  describe "environment defaults" do
    it "reads timeout, batching, and debug settings" do
      ENV["LANGFUSE_TIMEOUT"] = "9"
      ENV["LANGFUSE_FLUSH_AT"] = "25"
      ENV["LANGFUSE_FLUSH_INTERVAL"] = "1.5"
      ENV["LANGFUSE_DEBUG"] = "true"
      debug_logger = Logger.new(StringIO.new, level: Logger::DEBUG)
      allow(Logger).to receive(:new).with($stdout, level: Logger::DEBUG).and_return(debug_logger)

      config = described_class.new

      expect(config.timeout).to eq(9)
      expect(config.batch_size).to eq(25)
      expect(config.flush_interval).to eq(1.5)
      expect(config.logger).to equal(debug_logger)
    ensure
      clear_environment
    end

    it "prefers explicit Ruby settings" do
      ENV["LANGFUSE_TIMEOUT"] = "9"
      ENV["LANGFUSE_FLUSH_AT"] = "25"
      ENV["LANGFUSE_FLUSH_INTERVAL"] = "1.5"
      ENV["LANGFUSE_DEBUG"] = "true"

      config = described_class.new do |candidate|
        candidate.timeout = 12
        candidate.batch_size = 30
        candidate.flush_interval = 2
        candidate.logger = Logger.new(StringIO.new, level: Logger::ERROR)
      end

      expect(config.timeout).to eq(12)
      expect(config.batch_size).to eq(30)
      expect(config.flush_interval).to eq(2)
      expect(config.logger.level).to eq(Logger::ERROR)
    ensure
      clear_environment
    end

    it "does not change the Rails logger level when debug logging is enabled" do
      ENV["LANGFUSE_DEBUG"] = "true"
      rails_logger = Logger.new(StringIO.new, level: Logger::WARN)
      debug_logger = Logger.new(StringIO.new, level: Logger::DEBUG)
      stub_const("Rails", Class.new)
      allow(Rails).to receive_messages(respond_to?: true, logger: rails_logger)
      allow(Logger).to receive(:new).with($stdout, level: Logger::DEBUG).and_return(debug_logger)

      config = described_class.new

      expect(config.logger).to equal(debug_logger)
      expect(rails_logger.level).to eq(Logger::WARN)
    ensure
      clear_environment
    end

    it "raises ConfigurationError for non-numeric values" do
      invalid_values = {
        "LANGFUSE_TIMEOUT" => "slow",
        "LANGFUSE_FLUSH_AT" => "many",
        "LANGFUSE_FLUSH_INTERVAL" => "often"
      }

      invalid_values.each do |key, value|
        ENV[key] = value

        expect { described_class.new }.to raise_error(Langfuse::ConfigurationError, /#{key}/)

        ENV.delete(key)
      end
    ensure
      clear_environment
    end

    def clear_environment
      %w[
        LANGFUSE_TIMEOUT
        LANGFUSE_FLUSH_AT
        LANGFUSE_FLUSH_INTERVAL
        LANGFUSE_DEBUG
      ].each { |key| ENV.delete(key) }
    end
  end
end
