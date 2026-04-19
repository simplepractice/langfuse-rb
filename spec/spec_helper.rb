# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  # Maintain high coverage standards
  minimum_coverage 95
end

require "langfuse"
require "opentelemetry/sdk"
require "webmock/rspec"
require "logger"
require "fileutils"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Disable external HTTP requests by default
  WebMock.disable_net_connect!(allow_localhost: false)

  # Set up test log file before any tests run
  config.before(:suite) do
    FileUtils.mkdir_p("log")
    config.add_setting :test_logger
    config.test_logger = Logger.new("log/test.log")
    OpenTelemetry.tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
  end

  # Reset global Langfuse state before each test
  config.before do
    ENV.delete("LANGFUSE_PUBLIC_KEY")
    ENV.delete("LANGFUSE_SECRET_KEY")
    ENV.delete("LANGFUSE_BASE_URL")
    ENV.delete("LANGFUSE_TRACING_ENVIRONMENT")
    ENV.delete("LANGFUSE_RELEASE")

    # Stub OTLP endpoint BEFORE reset (which may flush traces)
    # (tests can override this with more specific stubs if needed)
    stub_request(:post, %r{/api/public/otel/v1/traces})
      .to_return(status: 200, body: "", headers: {})

    Langfuse.reset!

    # Configure logger to write to log file instead of stdout
    Langfuse.configure do |c|
      c.public_key = "pk_test"
      c.secret_key = "sk_test"
      c.base_url = "https://cloud.langfuse.com"
      c.logger = RSpec.configuration.test_logger
    end

    OpenTelemetry.tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    OpenTelemetry.propagation = OpenTelemetry::Context::Propagation::NoopTextMapPropagator.new

    # Stub Logger.new to use test log file when using $stdout, but allow other outputs
    test_logger = RSpec.configuration.test_logger
    allow(Logger).to receive(:new).and_call_original
    allow(Logger).to receive(:new).with($stdout, any_args).and_return(test_logger)
    allow(Logger).to receive(:new).with($stdout).and_return(test_logger)
  end
end
