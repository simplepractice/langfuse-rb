# Getting Started

This guide shows how to install the SDK and create a trace.
It also shows how to verify the trace in Langfuse.
You can add prompts and scores after this verification.

## 1. Prepare the Environment

You need Ruby `>= 3.2.0`, a Langfuse project, and project API keys.

Set these variables in the process that runs the application:

```bash
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
LANGFUSE_BASE_URL=https://cloud.langfuse.com
```

`LANGFUSE_BASE_URL` is optional for Langfuse Cloud.
The SDK does not load `.env` files.
Load a `.env` file before SDK initialization.

## 2. Install the Gem

Add the SDK to your `Gemfile`:

```ruby
gem "langfuse-rb"
```

Then install dependencies:

```bash
bundle install
```

## 3. Configure the Singleton Client

The SDK reads credentials from the environment.
Use `Langfuse.configure` for application settings:

```ruby
require "langfuse"

Langfuse.configure do |config|
  config.environment = ENV.fetch("APP_ENV", "development")
  config.release = ENV["APP_RELEASE"]
end
```

In a Rails application, put this block in `config/initializers/langfuse.rb`.
See [RAILS.md](RAILS.md) for cache and job patterns.

`Langfuse.configure` stores configuration.
It does not replace the process-wide `OpenTelemetry.tracer_provider`.
The helper API uses an isolated Langfuse provider by default.
Read [TRACING.md](TRACING.md#opentelemetry-integration) before you install the provider globally.

You can check local client readiness without a network request:

```ruby
abort "Langfuse configuration is incomplete" unless Langfuse.configured?
```

This check does not validate credentials.
It also does not prove ingestion.
The tracing helpers use a no-op tracer when the configuration is invalid.
Thus, most request paths do not need this guard.

## 4. Create a Useful Trace

Use one trace for each self-contained unit of work.
Use stable action names.
Put meaningful input and output on the root observation.

```ruby
class SupportAnswerService
  def initialize(llm_client:)
    @llm_client = llm_client
  end

  def call(user:, question:)
    Langfuse.propagate_attributes(
      user_id: user.id.to_s,
      session_id: "support-#{user.id}",
      tags: ["support"]
    ) do
      Langfuse.observe("answer-support-question", input: { question: question }) do |root|
        answer = root.start_observation("generate-answer", as_type: :generation) do |generation|
          generation.model = "gpt-4.1-mini"
          generation.input = { question: question }

          response = @llm_client.chat(question)

          generation.update(
            output: response.fetch(:content),
            usage_details: response.fetch(:usage)
          )

          response.fetch(:content)
        end

        root.update(output: { answer: answer })
        answer
      end
    end
  end
end
```

This creates:

- One root observation for the support workflow.
- One nested generation for the model call.
- Root input and output for trace-level review.
- Model and token information on the generation.
- User, session, environment, and tag values for filters.

See [TRACING.md](TRACING.md) for events, background jobs, custom trace IDs, masking, and OpenTelemetry ownership.

## 5. Flush Before Immediate Readback

The SDK exports data in batches.
A normal process exit flushes pending data automatically.
Long-running applications do not need to flush each request.

Call `Langfuse.force_flush` at an explicit durability boundary.
Also call it before an immediate verification read:

```ruby
Langfuse.force_flush
```

The normal exit hook cannot run after abrupt termination such as `SIGKILL`.

## 6. Verify Backend Ingestion

Keep the trace ID returned by the root observation when you need deterministic readback:

```ruby
trace_id = nil

Langfuse.observe("verify-sdk", input: { source: "getting-started" }) do |root|
  trace_id = root.trace_id
  root.update(output: { status: "ok" })
end

Langfuse.force_flush

rows = Langfuse.client.list_observations(
  trace_id: trace_id,
  fields: "core,basic,io"
).fetch("data")

raise "trace was not ingested" unless rows.any? { |row| row["name"] == "verify-sdk" }
```

Ingestion can have a short delay.
A deployment probe must retry the bounded read.
Do not use an unbounded project scan.

The Langfuse CLI provides an independent read path:

```bash
export LANGFUSE_HOST="${LANGFUSE_BASE_URL:-https://cloud.langfuse.com}"
npx --yes langfuse-cli@latest api observations list \
  --trace-id "$TRACE_ID" \
  --fields core,basic,io \
  --json
```

CLI JSON output contains `status`, `headers`, and `body`.
Observation rows are in `body.data`.
See [DATA_ACCESS.md](DATA_ACCESS.md) for pagination, metrics, score reads, and a complete verification procedure.

## 7. Add a Managed Prompt

Create a prompt in Langfuse.
Then, fetch the prompt by a stable label:

```ruby
prompt = Langfuse.client.get_prompt("support-answer", label: "production")

expected_variables = ["customer.name", "question"]
raise "prompt contract changed" unless prompt.variables == expected_variables

messages = prompt.compile(
  customer: { name: "Alice" },
  question: "How do I reset my password?"
)
```

See [PROMPTS.md](PROMPTS.md) for text and chat prompts, message placeholders, fallbacks, versioning, and caching.

## 8. Add Scores Deliberately

Use asynchronous score creation for inline telemetry:

```ruby
Langfuse.create_score(
  name: "helpful",
  value: true,
  trace_id: trace_id,
  data_type: :boolean
)
```

Use synchronous score creation when the caller needs delivery confirmation:

```ruby
score_id = Langfuse.create_score!(
  id: "feedback-#{feedback.id}",
  name: "helpful",
  value: true,
  trace_id: trace_id,
  data_type: :boolean
)
```

See [SCORING.md](SCORING.md) for delivery semantics, score types, environment inheritance, batching, and idempotency.

## Next Steps

- [Prompt Management](PROMPTS.md) for managed prompt workflows
- [Tracing](TRACING.md) for trace design and OpenTelemetry integration
- [Scoring](SCORING.md) for evaluation and feedback
- [Data Access](DATA_ACCESS.md) for SDK and CLI queries
- [Configuration](CONFIGURATION.md) for production controls
- [Testing Tracing](TESTING.md) for network-free span assertions
