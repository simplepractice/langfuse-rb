# Getting Started with Langfuse Ruby SDK

This is the happy path for a new consumer. The goal is simple: configure the SDK once, fetch a real prompt, send a real trace, and know where to go next without guessing how tracing works.

## Before You Start

- Ruby `>= 3.2.0`
- A Langfuse project with API keys
- At least one prompt created in the Langfuse UI

## 1. Install the Gem

```ruby
gem "langfuse-rb"
```

Then install dependencies:

```bash
bundle install
```

## 2. Configure Langfuse Once at Startup

Rails first, because that is the common consumer path.

```ruby
# config/initializers/langfuse.rb
Langfuse.configure do |config|
  config.public_key = Rails.application.credentials.dig(:langfuse, :public_key)
  config.secret_key = Rails.application.credentials.dig(:langfuse, :secret_key)
  config.base_url = ENV.fetch("LANGFUSE_BASE_URL", "https://cloud.langfuse.com")

  config.cache_backend = :rails
  config.cache_ttl = 300
  config.cache_stale_ttl = 300
end
```

Plain Ruby uses the same API:

```ruby
require "langfuse"

Langfuse.configure do |config|
  config.public_key = ENV["LANGFUSE_PUBLIC_KEY"]
  config.secret_key = ENV["LANGFUSE_SECRET_KEY"]
  config.base_url = ENV.fetch("LANGFUSE_BASE_URL", "https://cloud.langfuse.com")
end
```

`Langfuse.configure` stores configuration only. It does not replace `OpenTelemetry.tracer_provider`. The default onboarding path is isolated tracing through the Langfuse helpers. If you want Langfuse to become the global OpenTelemetry provider, that is an explicit later step in [TRACING.md](TRACING.md#opentelemetry-integration).

For the full config surface, see [CONFIGURATION.md](CONFIGURATION.md).

## 3. Fetch and Compile a Prompt

Create a prompt in the Langfuse UI first. For example:

- Name: `support-answer`
- Type: chat
- Label: `production`

Then fetch and compile it in your app:

```ruby
prompt = Langfuse.client.get_prompt("support-answer", label: "production")

messages = prompt.compile(
  customer_name: "Alice",
  question: "How do I reset my password?"
)
```

If you prefer the one-call version:

```ruby
messages = Langfuse.client.compile_prompt(
  "support-answer",
  label: "production",
  variables: {
    customer_name: "Alice",
    question: "How do I reset my password?"
  }
)
```

More prompt patterns live in [PROMPTS.md](PROMPTS.md).

## 4. Send Your First Real Trace

Use a root observation for the workflow, then nest the model call as a generation. This is the pattern most consumers actually want.

```ruby
class SupportAnswerService
  def initialize(llm_client:)
    @llm_client = llm_client
  end

  def call(user:, question:)
    Langfuse.propagate_attributes(
      user_id: user.id.to_s,
      session_id: "support-#{user.id}"
    ) do
      Langfuse.observe("support-answer", input: { question: question }) do |root|
        prompt = Langfuse.client.get_prompt("support-answer", label: "production")
        messages = prompt.compile(
          customer_name: user.name,
          question: question
        )

        answer = root.start_observation("llm-response", as_type: :generation) do |gen|
          gen.model = "gpt-4.1-mini"
          gen.input = messages

          response = @llm_client.chat(
            parameters: {
              model: "gpt-4.1-mini",
              messages: messages
            }
          )

          answer = response.dig("choices", 0, "message", "content")

          gen.update(
            output: answer,
            usage_details: {
              prompt_tokens: response.dig("usage", "prompt_tokens"),
              completion_tokens: response.dig("usage", "completion_tokens"),
              total_tokens: response.dig("usage", "total_tokens")
            }
          )

          answer
        end

        root.event(name: "reply-generated", input: { channel: "support" })
        root.update(output: { answer: answer })

        answer
      end
    end
  end
end
```

Why this shape matters:

- The root observation gives you a real trace entrypoint
- The nested generation carries model-specific fields like `model` and `usage_details`
- `root.event(...)` persists a point-in-time annotation on the active observation
- `root.update(...)` persists the final workflow output instead of leaving the trace half-empty

Plain Ruby is the same pattern without Rails wrappers:

```ruby
Langfuse.observe("support-answer", input: { question: question }) do |root|
  answer = root.start_observation("llm-response", as_type: :generation) do |gen|
    gen.model = "gpt-4.1-mini"
    # ...
  end

  root.update(output: { answer: answer })
end
```

For deeper tracing patterns, see [TRACING.md](TRACING.md).

## 5. Verify It Worked

After running the code:

1. Open the Langfuse UI.
2. Find the `support-answer` trace.
3. Confirm you can see:
   - the root observation input and output
   - the nested `llm-response` generation
   - usage details on the generation
   - the `reply-generated` event

If you do not see traces, start with [ERROR_HANDLING.md](ERROR_HANDLING.md) and the Rails operational checks in [RAILS.md](RAILS.md#troubleshooting).

## 6. Add Scores Once Traces Exist

Do not invent a scoring workflow before the trace is working. First make the trace visible, then attach evaluation or feedback signals.

Example:

```ruby
Langfuse.observe("support-answer") do |root|
  # ... do work ...
  root.score_trace(name: "customer-satisfaction", value: 5)
end
```

Scoring details live in [SCORING.md](SCORING.md).

## What to Read Next

- [PROMPTS.md](PROMPTS.md) if prompt versioning and fallbacks are your next problem
- [TRACING.md](TRACING.md) if you need nested workflows, events, jobs, or OpenTelemetry integration
- [SCORING.md](SCORING.md) if you want feedback or eval signals on traces
- [RAILS.md](RAILS.md) if you are wiring this into controllers, services, or background jobs
