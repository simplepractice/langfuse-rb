# LLM Tracing Guide

This guide explains the current SDK tracing behavior.
For installation and initial configuration, start with [GETTING_STARTED.md](GETTING_STARTED.md).

## Mental Model

- A root observation becomes the root of a trace.
- Do not create a trace separately.
- Child observations create nested spans inside that trace.
- Use `:generation` for model calls.
- A generation can contain `model`, `usage_details`, and `cost_details`.
- `:event` is a point-in-time observation with no duration.
- `Langfuse.configure` stores configuration only.
- Module-level tracing uses the internal Langfuse tracer provider when tracing is ready.

## Design the Trace Before Instrumenting It

Use a stable trace data contract for diagnostics, dashboards, evaluations, and experiments:

- Use one trace for each self-contained unit of work.
- Use a shared `session_id` for a sequence of related traces.
- Use stable, action-oriented names such as `retrieve-context` and `generate-answer`.
- Do not put IDs, retry numbers, or model names in observation names.
- Put the workflow input and final output on the root observation.
- Use the most specific child type.
- Use `:generation` for model calls and `:retriever` for retrievals.
- Use `:tool` for tools and `:agent` for agent executions.
- Nest tool and generation work under the workflow or agent that owns it.
- Record model and token usage on generations.
- Link the managed prompt when you use one.
- Put request IDs, feature flags, and diagnostic context in metadata.
- Use tags for stable business dimensions.
- Set `environment`.
- Mask sensitive data before export.

Treat names as durable API identifiers.
If you change a name, saved views, metric queries, and evaluators can stop matching the observation.

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

The root observation:

- Creates the trace entry point.
- Stores workflow-level output.
- Provides a parent for child work.

## Nest Generations Inside the Workflow

Use a child generation for the model call.
Do not put all model data in the root span.

```ruby
Langfuse.observe("support-answer", input: { question: question }) do |root|
  prompt = Langfuse.client.get_prompt("support-answer", label: "production")
  messages = prompt.compile(customer_name: user.name, question: question)

  answer = root.start_observation("openai-chat", { prompt: prompt }, as_type: :generation) do |gen|
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

This shape keeps workflow state on the root observation.
It keeps model-specific state on the generation observation.

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

For cross-service propagation through OpenTelemetry baggage, use `as_baggage: true`.
The application must also configure the baggage gem and its header propagation pipeline.

## Background Jobs and Async Work

ActiveJob and Sidekiq do not continue Langfuse trace context across processes.
Pass the required context explicitly.

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
- the job creates a new application root inside that trace
- this is usually enough for consumer workflows

A trace ID does not contain a parent observation ID or an existing root claim. Separate jobs that use only the same `trace_id:` can therefore create multiple application roots. Propagate the full OpenTelemetry parent context when one observation tree must continue across services.

Use separate traces and a shared `session_id` when jobs are related but each job is a self-contained unit of work.

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

- assigning one workflow trace to a durable application record
- regenerating the same trace ID for scores or reads
- matching an external trace ID at the first application entry point

Do not reuse a trace ID as a replacement for parent context. Each disjoint observation tree can become an application root.

Do not use secrets or raw PII as seeds.

## OpenTelemetry Integration

### Direct v4 Ingestion

The SDK sends completed spans to `/api/public/otel/v1/traces`. The exporter uses Basic Authentication and gzip compression.

The exporter also sends `x-langfuse-ingestion-version: 4`. This header selects the direct Langfuse v4 ingestion path. The SDK does not send a second legacy event.

Direct v4 ingestion requires Langfuse Cloud or a self-hosted Langfuse v4 server. Pin `langfuse` to `0.10.1` to restore the previous ingestion header behavior during rollback.

Each workflow must have one root observation. Put the overall input and output on that observation. The SDK experiment paths follow this rule.

The span processor marks the first exported span after a filtered parent as an application root. A baggage trace claim prevents a second root after a filtered intermediary span.

Use `Langfuse.propagate_attributes` for trace fields that must be available on child observations. The method can propagate `trace_name`, `user_id`, `session_id`, `metadata`, `tags`, `version`, `release`, and `environment`.

The exporter sends each completed span once. Do not reuse an observation ID to send an update after export.

The SDK has three OpenTelemetry ownership states.
Configure each state explicitly.

### 1. Default Isolated Langfuse Tracing

The SDK has this default behavior:

- `Langfuse.configure` does not change `OpenTelemetry.tracer_provider`.
- `Langfuse.configure` does not change `OpenTelemetry.propagation`.
- `Langfuse.observe(...)` uses the internal Langfuse tracer provider after tracing configuration.
- If tracing configuration is incomplete, module-level tracing uses a no-op tracer.
- The SDK logs one warning for the incomplete tracing configuration.

Thus, the SDK does not export ambient spans from an unrelated global OpenTelemetry provider by default.

### 2. Explicit Global Install with `Langfuse.tracer_provider`

If you want Langfuse to own the global OpenTelemetry provider, install it explicitly:

```ruby
Langfuse.configure do |config|
  config.public_key = ENV["LANGFUSE_PUBLIC_KEY"]
  config.secret_key = ENV["LANGFUSE_SECRET_KEY"]
end

OpenTelemetry.tracer_provider = Langfuse.tracer_provider
```

This configuration makes Langfuse the owner of the global provider:

- Spans from the global provider now use the Langfuse provider.
- `should_export_span` applies to the spans that Langfuse processes.
- After `Langfuse.shutdown` or `Langfuse.reset!`, the application must install the provider again.

If the application needs W3C or baggage propagation, configure `OpenTelemetry.propagation` in the application.
Langfuse does not install propagation.

### 3. Additional OpenTelemetry Backends Are Application-Owned

Langfuse does not automatically configure multi-destination OpenTelemetry export.

To use Langfuse with another OpenTelemetry backend, configure both backends in the application:

- Add more processors or exporters to the application-owned provider.
- Or, build and manage an application-owned provider pipeline.

Langfuse does not:

- Replace the application exporter topology automatically.
- Install a second backend by default.
- Enable export to multiple backends after a `Langfuse.configure` call.

## Operational Lifecycle

The SDK controls its internal tracing and scoring lifecycle:

- Invalid tracing configuration logs one warning and uses a no-op tracer.
- `Langfuse.configured?` checks local client readiness without network access.
- `LANGFUSE_TRACING_ENABLED=false` disables Langfuse tracing and scoring.
- `OTEL_SDK_DISABLED=true` disables trace export.
- `OTEL_SDK_DISABLED=true` does not disable score, prompt, or read APIs.
- A normal process exit flushes pending traces and scores.
- Queues and background workers reset in child processes from the Ruby `fork` path.

Do not add a second `at_exit` callback.
Use `Langfuse.shutdown` for an earlier shutdown.
Use `Langfuse.force_flush` before immediate readback.
An abrupt termination such as `SIGKILL` cannot flush buffered data.

For tests, inject `config.span_exporter` before tracing starts.
For batch processor telemetry, provide a fast and thread-safe `config.metrics_reporter`.
The application controls the reporter lifecycle.
Langfuse controls the configured exporter lifecycle.
See [CONFIGURATION.md](CONFIGURATION.md) and [TESTING.md](TESTING.md).

## Export Filtering

`config.should_export_span` filters spans that the Langfuse provider processes.

The SDK calls the filter once after each span finishes. The callback can use the span's final attributes.

The processor can defer a finished span while an ancestor span remains active. This delay prevents a provisional application root from reaching Langfuse. Finish each ancestor before you expect `flush` to export the deferred span.

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

Use the filter to reduce the spans that the Langfuse provider exports.

Export filtering does not prevent ambient-span overcapture.
Use provider isolation for this purpose.
The default isolated configuration does not export unrelated global spans to Langfuse.

Public helper predicates:

- `Langfuse.default_export_span?`
- `Langfuse.langfuse_span?`
- `Langfuse.genai_span?`
- `Langfuse.known_llm_instrumentor?`
- compatibility aliases: `Langfuse.is_default_export_span`, `Langfuse.is_langfuse_span`, `Langfuse.is_genai_span`, `Langfuse.is_known_llm_instrumentor`

The exact signatures live in [API_REFERENCE.md](API_REFERENCE.md).

## Best Practices

- Put workflow-level output on the root observation and model-level output on the generation.
- Capture `usage_details` on each applicable generation.
- Use descriptive observation names tied to real workflow steps.
- Use `Langfuse.propagate_attributes` early, before you start child observations.
- Keep `should_export_span` allocation-light and side-effect free.
- Add scores only after you have a stable trace flow. See [SCORING.md](SCORING.md).

After you instrument a path, execute the path.
Flush data at the verification boundary.
Then, fetch the stored observations.
See [DATA_ACCESS.md](DATA_ACCESS.md) for SDK reads and independent Langfuse CLI verification.

## Masking

If input or output contains sensitive data, configure `mask`.
The SDK changes the selected values before serialization:

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

### Export-stage masking with `mask_otel_spans`

`mask` runs while the SDK creates Langfuse-owned attributes; it never sees the raw
attributes of third-party spans (e.g. `gen_ai.*` attributes set by an OpenAI or
LangChain instrumentation). To transform those, configure the export-stage hook:

```ruby
Langfuse.configure do |config|
  config.mask_otel_spans = lambda { |params:|
    patches = params.spans.filter_map { |identifier, span|
      next unless span.attributes.key?("gen_ai.prompt")

      [
        identifier,
        Langfuse::OtelSpanPatch.new(
          delete_attributes: ["gen_ai.completion"],
          set_attributes: { "gen_ai.prompt" => "[REDACTED]" }
        )
      ]
    }.to_h

    Langfuse::MaskOtelSpansResult.new(span_patches: patches)
  }
end
```

The hook runs after `should_export_span` selects spans and just before the batch
is handed to the Langfuse OTLP exporter, so it sees exactly the spans this client
will export — Langfuse-owned and third-party alike. Returning `nil` exports the
batch unchanged. The hook receives `Langfuse::MaskOtelSpansParams` and returns
`Langfuse::MaskOtelSpansResult` with typed sparse patches. Errors fail closed:
the batch, span, or invalid attribute is omitted rather than exported unmasked.

The SDK changes only the Langfuse export copy.
Another OpenTelemetry backend receives the original spans.
Configure separate masking for that backend.
The two hooks are independent.
An application can configure one hook or both hooks.
The full contract is in [CONFIGURATION.md](CONFIGURATION.md#mask_otel_spans).

## See Also

- [DATA_ACCESS.md](DATA_ACCESS.md) — verify traces and query observations or metrics
- [CONFIGURATION.md](CONFIGURATION.md) — tracing controls, batching, exporters, and masking contracts
- [SCORING.md](SCORING.md) — attach evaluation and feedback signals
- [Langfuse trace best practices](https://langfuse.com/docs/observability/best-practices) — platform guidance for trace structure
