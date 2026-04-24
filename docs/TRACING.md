# LLM Tracing Guide

This guide is about the tracing behavior the SDK actually implements today. If you just need install and first-run setup, start with [GETTING_STARTED.md](GETTING_STARTED.md).

## Mental Model

- A root observation becomes the root of a trace. You do not create traces separately.
- Child observations create nested spans inside that trace.
- `:generation` is the right type for model calls because it carries model-specific fields like `model`, `usage_details`, and `cost_details`.
- `:event` is a point-in-time observation with no duration.
- `Langfuse.configure` stores configuration only. Module-level tracing uses Langfuse's internal tracer provider when tracing is ready.

## Start with a Root Observation

Most applications need one root observation per user-visible workflow.

```ruby
result = Langfuse.observe("draft-summary", input: { document_id: document.id }) do |root|
  summary = summarize_document(document)

  root.update(
    output: { summary: summary },
    metadata: { source: "web" }
  )

  summary
end
```

This pattern does three things:

- creates the trace entrypoint
- gives you a place to persist workflow-level output
- gives child work somewhere correct to hang

## Nest Generations Inside the Workflow

Use a child generation for the actual model call instead of stuffing everything into one giant root span.

```ruby
Langfuse.observe("support-answer", input: { question: question }) do |root|
  prompt = Langfuse.client.get_prompt("support-answer", label: "production")
  messages = prompt.compile(customer_name: user.name, question: question)

  answer = root.start_observation("openai-chat", as_type: :generation) do |gen|
    gen.model = "gpt-4.1-mini"
    gen.input = messages
    gen.model_parameters = { temperature: 0.2 }

    response = llm_client.chat(
      parameters: {
        model: "gpt-4.1-mini",
        messages: messages,
        temperature: 0.2
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

  root.update(output: { answer: answer })
end
```

That shape is better than a flat one-span trace because it keeps workflow state on the root and model-specific state on the generation where Langfuse expects it.

## Record Events That Actually Persist Payloads

There are two patterns that work. Use them on purpose.

### Standalone Event Observation

If you want a payload-bearing event observation, pass the payload when you create it:

```ruby
Langfuse.observe(
  "job-enqueued",
  {
    input: { document_id: document.id, queue: "default" },
    level: "DEFAULT"
  },
  as_type: :event
)
```

### Point-in-Time Annotation on an Existing Observation

If you already have an active root or child observation, annotate it with `event(...)`:

```ruby
Langfuse.observe("support-answer") do |root|
  root.event(name: "cache-hit", input: { key: "support-answer:v3" })
end
```

### What Not to Do

Do not create a standalone `:event` observation and then try to attach payload in a later block update. The event auto-ends immediately when it is created, so that payload arrives too late. If you need payload, pass it at creation time or use `root.event(...)`.

## Propagate Trace-Level Attributes

Use `Langfuse.propagate_attributes` for trace-level fields that should follow the current workflow.

```ruby
Langfuse.propagate_attributes(
  user_id: current_user.id.to_s,
  session_id: "support-session-123",
  metadata: { environment: Rails.env },
  tags: ["support", "chat"]
) do
  Langfuse.observe("support-answer") do |root|
    root.start_observation("prompt-fetch") do |span|
      span.update(output: { prompt_name: "support-answer" })
    end
  end
end
```

Important boundaries:

- it updates the currently active span if one exists
- it also applies to spans created after the propagation block starts
- it does not retroactively rewrite spans that already ended

If you need cross-service propagation via OpenTelemetry baggage, use `as_baggage: true` and make sure the host app has the baggage gem and its own header propagation pipeline configured.

## Background Jobs and Async Work

ActiveJob or Sidekiq does not magically continue Langfuse trace context across processes. You need to pass something explicit.

### Good Default: Pass the `trace_id`

Controller or request path:

```ruby
Langfuse.propagate_attributes(user_id: current_user.id.to_s) do
  Langfuse.observe("document-upload", input: { filename: upload.original_filename }) do |root|
    document = Document.create!(file: upload)

    ProcessDocumentJob.perform_later(document.id, root.trace_id)
    root.event(name: "job-enqueued", input: { document_id: document.id, queue: "default" })
  end
end
```

Background job:

```ruby
class ProcessDocumentJob < ApplicationJob
  def perform(document_id, trace_id)
    document = Document.find(document_id)

    Langfuse.observe("process-document", { input: { document_id: document_id } }, trace_id: trace_id) do |root|
      text = root.start_observation("extract-text") do |span|
        extracted_text = extract_text(document)
        span.update(output: { characters: extracted_text.length })
        extracted_text
      end

      root.start_observation("summarize", as_type: :generation) do |gen|
        gen.model = "gpt-4.1-mini"
        summary = summarize(text)
        gen.update(output: summary)
        document.update!(summary: summary)
      end
    end
  end
end
```

What that means:

- `trace_id:` joins the same trace
- the job creates a new root observation inside that trace
- this is usually enough for consumer workflows

If you need true parent-child continuation across process or service boundaries, that is host-application OpenTelemetry context propagation work. Langfuse does not do that wiring for you automatically.

## Custom Trace IDs

Use custom trace IDs when your application already has a durable identifier you want to correlate with Langfuse.

```ruby
trace_id = Langfuse.create_trace_id(seed: "order-#{order.id}")

Langfuse.observe("process-order", trace_id: trace_id, input: { order_id: order.id }) do |root|
  root.update(output: { status: "processed" })
end
```

Good use cases:

- retries that should land on the same logical trace
- linking traces to a durable application record
- async workflows where a later worker needs to rejoin the trace

Do not use secrets or raw PII as seeds.

## OpenTelemetry Integration

There are three states. Keep them separate in your head or you will misconfigure this.

### 1. Default Isolated Langfuse Tracing

This is the default behavior:

- `Langfuse.configure` does not mutate `OpenTelemetry.tracer_provider`
- `Langfuse.configure` does not mutate `OpenTelemetry.propagation`
- `Langfuse.observe(...)` uses Langfuse's internal tracer provider once tracing is configured
- if tracing config is incomplete, module-level tracing falls back to a no-op tracer and logs one warning

This is why ambient spans from some unrelated global OpenTelemetry provider are not exported to Langfuse by default.

### 2. Explicit Global Install with `Langfuse.tracer_provider`

If you want Langfuse to own the global OpenTelemetry provider, install it explicitly:

```ruby
Langfuse.configure do |config|
  config.public_key = ENV["LANGFUSE_PUBLIC_KEY"]
  config.secret_key = ENV["LANGFUSE_SECRET_KEY"]
end

OpenTelemetry.tracer_provider = Langfuse.tracer_provider
```

That is an ownership decision, not a free convenience:

- spans created through the global provider now run through Langfuse's provider
- `should_export_span` now applies to those spans because Langfuse is actually processing them
- if you call `Langfuse.shutdown` or `Langfuse.reset!`, you own reinstalling the provider afterward

If your app also needs W3C propagation or baggage propagation, configure `OpenTelemetry.propagation` yourself. Langfuse does not install that for you.

### 3. Additional OpenTelemetry Backends Are Application-Owned

Langfuse does not automatically configure multi-destination OpenTelemetry export.

If you want Langfuse plus another OTel backend, wire that in explicitly in your application:

- add more processors/exporters to the provider you own
- or build and manage your own provider pipeline

What Langfuse will not do for you:

- replace your app's exporter topology automatically
- install a second backend by default
- infer whether you want multi-export just because you called `Langfuse.configure`

## Export Filtering

`config.should_export_span` is a filter on spans handled by Langfuse's provider. That is it.

```ruby
Langfuse.configure do |config|
  config.public_key = ENV["LANGFUSE_PUBLIC_KEY"]
  config.secret_key = ENV["LANGFUSE_SECRET_KEY"]
  config.should_export_span = lambda { |span|
    Langfuse.default_export_span?(span) &&
      span.instrumentation_scope&.name != "my_framework.worker"
  }
end
```

Use it when you want to narrow what Langfuse exports after Langfuse owns the provider path.

Do not pretend filtering is the fix for ambient-span overcapture. Isolation is the fix. The default isolated setup already prevents random global spans from leaking into Langfuse.

Public helper predicates:

- `Langfuse.default_export_span?`
- `Langfuse.langfuse_span?`
- `Langfuse.genai_span?`
- `Langfuse.known_llm_instrumentor?`
- compatibility aliases: `Langfuse.is_default_export_span`, `Langfuse.is_langfuse_span`, `Langfuse.is_genai_span`, `Langfuse.is_known_llm_instrumentor`

The exact signatures live in [API_REFERENCE.md](API_REFERENCE.md).

## Best Practices

- Put workflow-level output on the root observation and model-level output on the generation.
- Capture `usage_details` on every generation you care about.
- Use descriptive observation names tied to real workflow steps.
- Use `Langfuse.propagate_attributes` early, before you start child observations.
- Keep `should_export_span` allocation-light and side-effect free.
- Add scores only after you have a stable trace flow. See [SCORING.md](SCORING.md).

## Masking

If inputs or outputs contain sensitive data, configure `mask` and let the SDK redact values before serialization:

```ruby
Langfuse.configure do |config|
  config.public_key = ENV["LANGFUSE_PUBLIC_KEY"]
  config.secret_key = ENV["LANGFUSE_SECRET_KEY"]
  config.mask = lambda { |data:|
    case data
    when Hash
      data.transform_values { "[REDACTED]" }
    else
      "[REDACTED]"
    end
  }
end
```

Masking applies to observation `input`, `output`, and `metadata`. The full configuration contract is in [CONFIGURATION.md](CONFIGURATION.md#mask).
