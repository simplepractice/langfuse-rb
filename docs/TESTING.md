# Testing Tracing

Use an application-owned in-memory exporter when a test must inspect completed
Langfuse spans. This approach runs observations through Langfuse's normal sampler,
filter, enrichment, masking, batch processor, and exporter pipeline. It does not
send trace data over HTTP.

## RSpec

Create one exporter for the test process. Configure it before tracing starts.
Dummy API keys are still required because tracing validates all connection settings.
Ensure the test process does not inherit `LANGFUSE_TRACING_ENABLED=false` or
`OTEL_SDK_DISABLED=true`; either setting prevents the exporter from receiving spans.

```ruby
# spec/support/langfuse.rb
require "opentelemetry/sdk"

LANGFUSE_TEST_EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new

Langfuse.configure do |config|
  config.public_key = "pk-test"
  config.secret_key = "sk-test"
  config.span_exporter = LANGFUSE_TEST_EXPORTER
end

RSpec.configure do |config|
  config.around(:each, :langfuse) do |example|
    Langfuse.force_flush
    LANGFUSE_TEST_EXPORTER.reset

    begin
      example.run
    ensure
      Langfuse.force_flush
    end
  end
end
```

Flush before each assertion because Langfuse uses the normal batch processor.

```ruby
RSpec.describe SummarizationService, :langfuse do
  it "emits a generation span" do
    described_class.call("hello")
    Langfuse.force_flush

    span = LANGFUSE_TEST_EXPORTER.finished_spans.find { |item| item.name == "summarize" }
    expect(span.attributes["langfuse.observation.type"]).to eq("generation")
  end
end
```

## Minitest

The same process-level exporter works with Minitest. Use lifecycle callbacks to
flush old work before clearing the buffer and to flush completed test work during
teardown.

```ruby
# test/support/langfuse.rb
require "opentelemetry/sdk"

LANGFUSE_TEST_EXPORTER = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new

Langfuse.configure do |config|
  config.public_key = "pk-test"
  config.secret_key = "sk-test"
  config.span_exporter = LANGFUSE_TEST_EXPORTER
end

module LangfuseTestTracing
  def before_setup
    super
    Langfuse.force_flush
    LANGFUSE_TEST_EXPORTER.reset
  end

  def after_teardown
    Langfuse.force_flush
    super
  end
end
```

Include the module in tests that inspect spans:

```ruby
class SummarizationServiceTest < ActiveSupport::TestCase
  include LangfuseTestTracing

  test "emits a generation span" do
    SummarizationService.call("hello")
    Langfuse.force_flush

    span = LANGFUSE_TEST_EXPORTER.finished_spans.find { |item| item.name == "summarize" }
    assert_equal "generation", span.attributes["langfuse.observation.type"]
  end
end
```

## Lifecycle and Concurrency

Langfuse's internal tracer provider owns the configured exporter after tracing
starts. `Langfuse.shutdown` and `Langfuse.reset!` shut down that exporter. Do not
reuse the exporter after either call. Create and configure a new exporter when you
rebuild tracing.

Prefer `Langfuse.force_flush` and `InMemorySpanExporter#reset` between examples.
`Langfuse.reset!` also rebuilds the prompt and score client, so it is not a
tracing-only test reset.

A span that starts before an exporter buffer reset and finishes afterward can appear
in the next example. Finish all jobs and threads before assertions. Serialize tests
that emit Langfuse spans. Process-based parallel workers have separate exporters and
are safe. Thread-based parallel examples must be serialized.

This recipe is unsupported after an application assigns
`OpenTelemetry.tracer_provider = Langfuse.tracer_provider`. That assignment makes
Langfuse's provider process-global and extends its lifecycle beyond this recipe.

Changing `span_exporter` after tracing starts produces a warning. The active provider
keeps its original exporter until `Langfuse.reset!` rebuilds tracing.
