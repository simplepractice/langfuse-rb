# Scoring

Attach scores to traces, observations, sessions, or dataset runs. The module-level
methods delegate to `Langfuse.client`.

## Choose a Delivery Mode

| Method | Contract | Return |
| --- | --- | --- |
| `create_score` | Queues asynchronous telemetry; may drop a score at capacity. | `nil` |
| `create_score!` | Waits for HTTP acceptance; raises on failure or rejection. | Score ID, or `nil` when telemetry is disabled |

HTTP acceptance does not guarantee immediate read visibility. For retries across
calls, reuse both `id` and `timestamp`, along with the score data:

```ruby
feedback = {
  id: "feedback-123", timestamp: Time.now.utc,
  name: "helpful", value: true, data_type: :boolean, trace_id: trace_id
}
Langfuse.create_score!(**feedback) # Reuse this payload if the call must be retried.
```

Otherwise, the SDK creates an ID and timestamp before sending. Automatic transport
retries preserve both. Synchronous delivery bypasses the asynchronous queue and
trace sampling.

### Backend Compatibility

Both methods send arrays to `POST /api/public/scores`. This requires Langfuse Cloud
or self-hosted Langfuse **v4.59.0 or later**, matching the
[upstream batch Scores API contract](https://langfuse.com/docs/observability/sdk/upgrade-path/js-v5-to-v6#minimum-versions).
There is no legacy transport fallback. Keep `langfuse-rb` at `0.12.4` until an older
backend is upgraded.

An explicit score `environment` overrides `config.environment`; otherwise Langfuse
uses its default environment. `tracing_enabled = false` disables both score methods.
`OTEL_SDK_DISABLED=true` disables tracing only.

## Score Types

| `data_type` | Accepted value | Constraints |
| --- | --- | --- |
| `:numeric` (default) | Numeric | Use a finite, JSON-serializable number. |
| `:boolean` | `true`, `false`, `0`, or `1` | Sent as `0` or `1`; v3 reads return a Boolean. |
| `:categorical` | String | Category label. |
| `:text` | String | 1–500 characters. |
| `:correction` | String | Requires `trace_id`; no SDK character limit. |

A correction replaces a trace or observation output. Supply structured corrections
as JSON text; the SDK does not serialize an object into a correction string.
Langfuse persists the score name as `"output"`. Corrections cannot target a session,
dataset run, or score config.

```ruby
Langfuse.create_score(
  name: "output", value: "The corrected answer", data_type: :correction,
  trace_id: trace_id, observation_id: observation_id
)
```

Use both `trace_id` and `observation_id` when scoring a specific observation.
For trace-level feedback, omit `observation_id`. Optional `comment`, `metadata`,
and `config_id` describe the score; full signatures are in the
[API Reference](API_REFERENCE.md#scoring).

Experiment `Evaluation` objects accept only numeric, boolean, and categorical
metrics. Create text notes and corrections with the general score methods.

## Score Active Work

```ruby
Langfuse.observe("generate-answer", as_type: :generation) do |generation|
  generation.update(output: "A programming language.")
  Langfuse.score_active_observation(name: "correct", value: true, data_type: :boolean)
end
```

`score_active_observation` uses both IDs from the active OpenTelemetry span.
`score_active_trace` uses only its trace ID. With telemetry enabled, missing valid
active context raises `ArgumentError`. Both use asynchronous delivery.
An observation also provides `score_trace(...)` for its own trace.

For later feedback, store `observation.trace_id` and, when needed, `observation.id`.
Alternatively, derive a trace ID from an application identifier with
`Langfuse.create_trace_id(seed: "order-123")`; use that same ID when starting the trace.

## Batching Behavior

Defaults are 50 scores per flush threshold, a 10-second flush interval, and capacity
for 100,000 pending scores, including in-flight work. Configure them before the
client is built:

```ruby
Langfuse.configure do |config|
  config.batch_size = 100
  config.flush_interval = 5
  config.score_queue_capacity = 20_000
end
```

Each asynchronous request is capped at 100 scores and 1,000,000 JSON bytes. A single
oversized score or a new score arriving at a full queue is logged and dropped.
The payload is snapshotted at enqueue time; later caller mutations do not change it.

Score requests retry connection failures, timeouts, HTTP 429, and all HTTP 5xx
responses up to twice. After those attempts:

- Retryable failures retain asynchronous batches for a later flush.
- Authentication failures retain the queue.
- Permanent HTTP failures are logged and discarded so later scores can proceed.
- A valid HTTP 207 response completes the batch. Rejected scores are logged;
  accepted scores are not resent. `create_score!` raises if its score was rejected.

`Langfuse.flush_scores` attempts immediate delivery. `Langfuse.force_flush` flushes
traces only. Normal process exit attempts both; queued scores are in memory and
can be lost during an outage or abrupt termination. A flush is not a persistence
acknowledgment. See [Data Access](DATA_ACCESS.md#read-scores) for independent readback.

## Sampling

Asynchronous scores with a lowercase 32-character hexadecimal `trace_id` follow
the client's deterministic `sample_rate`. Scores without a trace ID or with legacy
ID formats are kept. Active OpenTelemetry trace flags do not override this decision.
`create_score!` bypasses sampling.

The client snapshots `sample_rate` when built. To change it, reset Langfuse and
reapply configuration before rebuilding the client and tracing provider.
