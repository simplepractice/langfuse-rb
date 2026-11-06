# Tracing

A root observation starts a trace; children record work within that trace. Use
stable names and put workflow input/output on the root. Model calls belong in
`:generation` observations with model, usage, and prompt information.

## Observations and Generations

```ruby
Langfuse.observe("answer-question", input: question) do |root|
  answer = root.start_observation("generate-answer", as_type: :generation) do |generation|
    response = answer_question(question) # Your model adapter returns this data.
    generation.update(
      input: question, output: response.fetch(:text), model: response.fetch(:model),
      usage_details: { input: response.fetch(:input_tokens), output: response.fetch(:output_tokens) }
    )
    response.fetch(:text)
  end
  root.update(output: answer)
end
```

`Langfuse.observe` and `observation.start_observation` make the observation current
inside the block, return the block value, and end the span even if the block raises.
Exceptions are recorded and re-raised. Without a block, end the observation yourself:

```ruby
span = Langfuse.start_observation("process-document", { input: document_id })
begin
  span.update(output: process_document(document_id))
ensure
  span.end
end
```

The stateful call does not make the span current. Use `span.start_observation` to
create its children. Supply attributes as a positional hash to `start_observation`;
`Langfuse.observe` also accepts attribute keywords.

Types are `:span`, `:generation`, `:event`, `:embedding`, `:agent`, `:tool`, `:chain`,
`:retriever`, `:evaluator`, and `:guardrail`. See [API Reference](API_REFERENCE.md#tracing)
for attributes and setters. Updates after a span ends have no effect.

## Events

Standalone events end immediately. Pass their payload at creation, not in a later
block update:

```ruby
Langfuse.observe("job-enqueued", { input: { queue: "default" } }, as_type: :event)
```

For an OpenTelemetry event on an existing observation:

```ruby
Langfuse.observe("answer-question") do |root|
  root.event(name: "cache-hit", input: { prompt: "support-answer" })
end
```

## Propagate Trace Attributes

```ruby
Langfuse.propagate_attributes(
  user_id: "user-123", session_id: "conversation-456", tags: ["support"],
  metadata: { region: "us" }
) do
  Langfuse.observe("answer-question") { |root| root.update(output: "Done") }
end
```

Propagation updates the current span and new descendants. It cannot change ended
spans. Nested scopes merge metadata and tags; scalar values override inherited
values. Exiting restores the parent context but does not undo updates already made
to an active span.

Supported fields include `trace_name`, `user_id`, `session_id`, `version`, `release`,
`environment`, `metadata`, and `tags`. Scalar strings, metadata values, and tags
must be at most 200 characters. Propagated metadata values must be strings.
Environment must be 1–40 lowercase letters, digits, hyphens, or underscores and
must not start with `langfuse`. Invalid values are dropped with a warning.

`as_baggage: true` also places these fields in OpenTelemetry baggage. The application
must install the baggage dependency and configure header injection/extraction.
Do not put secrets in propagated headers.

## Custom Trace IDs and Background Work

```ruby
trace_id = Langfuse.create_trace_id(seed: "order-123")
Langfuse.observe("process-order", trace_id: trace_id) { |root| root.update(output: "Done") }
```

The same seed yields the same lowercase 32-character hexadecimal ID. Omitting the
seed generates a random ID. Do not use secrets as seeds.

An explicit `trace_id:` creates a parentless root even when another span is active.
It uses the root sampler and restores the previous context on block exit. Reusing
an ID creates another root; it does not update an earlier observation. If the
application replaces the provider's ID generator, explicit roots retain a placeholder
parent.

Passing only a trace ID to a background job joins the trace but does not restore a
parent observation, user, session, or existing root claim. Use separate traces with
a shared `session_id` for independent jobs, or application-managed OpenTelemetry
context propagation for an exact parent-child continuation. `start_observation`
accepts `parent_span_context:` for a specific parent; it cannot be combined with
`trace_id:`. See [Rails](RAILS.md#background-jobs) for a job example.

## OpenTelemetry Integration

By default, Langfuse uses an isolated internal provider. `configure` does not replace
`OpenTelemetry.tracer_provider` or `OpenTelemetry.propagation`. Unrelated global
spans are not exported to Langfuse. Invalid tracing configuration logs a warning
and makes the helper API use a no-op tracer.

To send other instrumentation through Langfuse's provider, install it explicitly:

```ruby
OpenTelemetry.tracer_provider = Langfuse.tracer_provider
```

Configure Langfuse first. This accessor raises on invalid tracing configuration.
After `Langfuse.reset!`, reconfigure and reinstall the provider if it must remain
global. After shutdown, reset before starting a new tracing lifecycle. Additional
backends and propagators are application-owned.

The default exporter sends gzip-compressed OTLP to `/api/public/otel/v1/traces`
with Basic Authentication and `x-langfuse-ingestion-version: 4`. It requires
Langfuse Cloud or self-hosted v4. Completed spans are not an update stream; do not
reuse observation IDs to amend exported records.

## Export Filtering

`should_export_span` replaces the default filter and runs once after a span ends:

```ruby
Langfuse.configure do |config|
  config.should_export_span = lambda do |span|
    Langfuse.default_export_span?(span) && span.instrumentation_scope&.name != "my.worker"
  end
end
```

It only filters spans processed by Langfuse's provider. Keep the callback fast and
side-effect free. The processor marks the first exported span after a filtered
parent as an application root. Completed spans can wait for active ancestors so
that root classification is final; end those ancestors before expecting a flush
to export descendants.

Other predicates are `langfuse_span?`, `genai_span?`, and `known_llm_instrumentor?`.
Their `is_*` compatibility aliases remain available.

## Masking

`mask` transforms Langfuse-created input, output, and metadata before serialization:

```ruby
Langfuse.configure do |config|
  config.mask = ->(data:) { "[REDACTED]" }
end
```

The callable receives each non-nil field and returns its replacement. If it raises,
the field becomes `"<fully masked due to failed mask function>"` and a warning is
logged. This hook does not mask score payloads or arbitrary third-party span attributes.

### Export-Stage Masking

Use `mask_otel_spans` to patch attributes on Langfuse's export copy, including those
created by third-party instrumentation:

```ruby
Langfuse.configure do |config|
  config.mask_otel_spans = lambda do |params:|
    patches = params.spans.filter_map do |identifier, span|
      next unless span.attributes.key?("gen_ai.prompt")

      [identifier, Langfuse::OtelSpanPatch.new(
        delete_attributes: ["gen_ai.completion"],
        set_attributes: { "gen_ai.prompt" => "[REDACTED]" }
      )]
    end.to_h
    Langfuse::MaskOtelSpansResult.new(span_patches: patches)
  end
end
```

The callback runs after filtering and before export. `params.spans` is a frozen hash
from `OtelSpanIdentifier` to read-only `OtelSpanData`. Snapshots expose IDs, name,
instrumentation scope, span attributes, and resource attributes. Reuse the supplied
identifiers as patch keys. Only span attributes can be changed; events, names,
resources, and IDs cannot be patched.

Return `nil` to leave the batch unchanged, or `MaskOtelSpansResult` containing sparse
`OtelSpanPatch` values. Missing or nil patches leave a span unchanged. Deletes run
before sets. Keys must be nonempty strings and values must be valid OpenTelemetry
attribute values, not nested hashes.

| Failure | Export result |
| --- | --- |
| Hook exception, invalid result container, or unknown span identifier | Drop the batch. |
| Invalid patch type or patch containers | Drop that span. |
| Invalid replacement value | Remove that attribute. |
| Invalid attribute key | Ignore that key and warn. |

Other exporters retain the original span data and need their own masking.
Set this hook before tracing starts; changing it requires a reset.

## Skill Availability

```ruby
Langfuse.configure do |config|
  config.skills = { available: Langfuse.discover_skills(dir: ".agents/skills") }
end

Langfuse.propagate_attributes(attach_skills: true) do
  Langfuse.observe("assistant", as_type: :agent) do |agent|
    agent.start_observation("plan", as_type: :generation) { |generation| generation.update(output: "Plan ready") }
  end
end
```

Discovery checks immediate non-hidden directories for a regular `SKILL.md`, follows
symlinks, and reads no skill contents. A `langfuse-skills.lock` in that directory
takes precedence over one in the working directory. Valid records supply names
and versions; otherwise directory names are used without versions. Installation
records do not verify later edits. Missing directories return `[]`; unreadable
paths, invalid locks, and duplicate names warn. Sorted directory order resolves
name collisions.

For a scope-specific list, use
`Langfuse.propagate_attributes(skills_available: [{ name: "summarize", version: 2 }]) { ... }`.
The list updates the current span and replaces inheritance: `[]` clears it and
`nil` inherits. Direct span attributes override propagated skills, which override
the configured catalog. Leaving a scope restores context, not attributes already
written to active spans.

The catalog is serialized when tracing starts and applies to new spans only inside
`attach_skills: true` scopes. Nested scopes inherit the flag; `false` disables
catalog attachment without clearing explicitly propagated skills. Neither skills
option travels as baggage.

The attribute is `langfuse.observation.skills_available`. It records availability,
not execution. See the [platform guide](https://langfuse.com/docs/skill-management/tracing)
for how Langfuse displays it.

## Flush and Shutdown

`Langfuse.force_flush` flushes completed traces; `Langfuse.flush_scores` flushes
scores. Normal exit attempts both. `shutdown` ends the lifecycle; `reset!` also
clears configuration. Outages and abrupt termination can still lose buffered data.
See [Configuration](CONFIGURATION.md#process-exit) for switches and lifecycle
ownership, [Testing](TESTING.md) for exporter injection, and
[Data Access](DATA_ACCESS.md) for persistence verification.
