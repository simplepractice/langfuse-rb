# Getting Started

You need Ruby `>= 3.2.0`, a Langfuse project, and project API keys. Tracing uses
Langfuse v4 ingestion. Score delivery requires Langfuse Cloud or self-hosted
Langfuse **v4.59.0 or later**.

## Install and Configure

Add `gem "langfuse-rb"` to your Gemfile and run `bundle install`.
Set credentials and the URL for your project's region or self-hosted instance:

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_SECRET_KEY=sk-lf-...
export LANGFUSE_BASE_URL=https://cloud.langfuse.com
```

The default URL is `https://cloud.langfuse.com`. The SDK does not load `.env` files.

```ruby
require "langfuse"

Langfuse.configure do |config|
  config.environment = ENV.fetch("APP_ENV", "development")
  config.release = ENV["APP_RELEASE"]
end
```

Configure before the first client or tracing call. In Rails, use an initializer;
see [Rails Integration](RAILS.md). The SDK uses its own OpenTelemetry provider by
default and does not replace the application's global provider.

`Langfuse.configured?` checks local client settings without a network request.
It does not authenticate the keys. Invalid tracing configuration makes the tracing
helpers log a warning and use a no-op tracer.

## Create a Trace

A root observation starts a trace. Child observations record steps within it.
Use `:generation` for model calls. This runnable example uses synthetic output:

```ruby
trace_id = nil

Langfuse.propagate_attributes(user_id: "demo-user", tags: ["quickstart"]) do
  Langfuse.observe("answer-question", input: "What is Ruby?") do |root|
    trace_id = root.trace_id
    answer = root.start_observation("generate-answer", as_type: :generation) do |generation|
      generation.update(input: "What is Ruby?", output: "A programming language.")
      "A programming language."
    end
    root.update(output: answer)
  end
end

Langfuse.force_flush
puts Langfuse.client.trace_url(trace_id)
```

Open the URL to inspect the root and generation. Ingestion can take time; see
[Data Access](DATA_ACCESS.md#verify-an-sdk-write-end-to-end) for bounded readback
and independent CLI verification.

## Add a Prompt or Score

Create a text prompt named `greeting` with content `Hello {{name}}!` and a
`production` label in Langfuse, then compile it:

```ruby
prompt = Langfuse.client.get_prompt("greeting", label: "production")
text = prompt.compile(name: "Alice")
```

Attach feedback to the trace from the example:

```ruby
Langfuse.create_score(name: "helpful", value: true, data_type: :boolean, trace_id: trace_id)
Langfuse.flush_scores
```

`create_score` queues telemetry; `create_score!` waits for HTTP acceptance and raises
on failure. See [Scoring](SCORING.md) for retry identity and delivery limits.

Normal process exit attempts to flush traces and scores. `force_flush` flushes
traces; `flush_scores` flushes scores. Neither guarantees persistence during an
outage, and abrupt termination can lose buffered data.

Continue with [Prompt Management](PROMPTS.md), [Tracing](TRACING.md), or
[Configuration](CONFIGURATION.md).
