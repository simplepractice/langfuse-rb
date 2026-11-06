# Data Access and Verification

Use current read APIs for stored observations, aggregates, and typed scores. They
return string-keyed response hashes with `data` and pagination metadata.

| Need | Method | Endpoint |
| --- | --- | --- |
| Spans, generations, events, or a trace's observation tree | `list_observations` | `/api/public/v2/observations` |
| Aggregate volume, latency, usage, cost, or scores | `query_metrics` | `/api/public/v2/metrics` |
| Typed scores | `list_scores` | `/api/public/v3/scores` |

The v2 endpoints require Langfuse Cloud or self-hosted v4. Prefer observations for
current trace traversal; `list_traces` and `get_trace` remain legacy APIs.

## Read Observations

Provide a trace ID or both time bounds. Start bounds are inclusive; end bounds
are exclusive.

```ruby
page = Langfuse.client.list_observations(
  trace_id: trace_id, fields: "core,basic,io,model,usage,prompt", limit: 100
)
page.fetch("data").each { |row| puts "#{row['type']} #{row['name']}" }
```

Without `fields`, the backend returns `core` and `basic`. Request additional fields
only when needed. Observation `input` and `output` are JSON-encoded strings;
use `JSON.parse` to recover the SDK-written value. The SDK does not decode these
fields automatically. `is_root_observation: true` selects logical application roots;
`parent_observation_id` filters physical parent relationships. A logical root can
have a physical parent when upstream spans were filtered.

### Cursor Pagination

Keep filters and bounds unchanged between pages:

```ruby
window_end = Time.now.utc
window_start = window_end - 3600
cursor = nil

loop do
  page = Langfuse.client.list_observations(
    from_start_time: window_start, to_start_time: window_end,
    type: "GENERATION", fields: "core,basic,usage", limit: 1000, cursor: cursor
  )
  page.fetch("data").each { |row| puts row.fetch("id") }
  cursor = page.dig("meta", "cursor")
  break unless cursor
end
```

## Query Metrics

Use server-side metrics when you need an aggregate rather than individual records:

```ruby
result = Langfuse.client.query_metrics(
  query: {
    view: "observations",
    metrics: [{ measure: "count", aggregation: "count" }],
    filters: [{ column: "traceId", operator: "=", value: trace_id, type: "string" }],
    fromTimestamp: (Time.now.utc - 3600).iso8601,
    toTimestamp: (Time.now.utc + 60).iso8601
  }
)
count = result.dig("data", 0, "count_count")
```

Views are `observations`, `scores-numeric`, `scores-boolean`, and `scores-categorical`.
The SDK accepts a Hash or JSON String; the backend validates the query. See the
[Metrics API](https://langfuse.com/docs/metrics/features/metrics-api) for available
measures and dimensions.

## Read Scores

```ruby
page = Langfuse.client.list_scores(
  trace_id: trace_id, fields: "details,subject", limit: 100
)
page.fetch("data").each { |score| puts "#{score['dataType']}: #{score['value'].inspect}" }
```

The v3 `value` is a number for `NUMERIC`, a Boolean for `BOOLEAN`, and a String for
`CATEGORICAL`, `TEXT`, or `CORRECTION`. Score pages also use `meta.cursor`; keep the
original filters when requesting subsequent pages. See
[API Reference](API_REFERENCE.md#data-access) for filters and subject constraints.

## Verify an SDK Write End to End

SDK acceptance, HTTP delivery, and backend persistence are separate outcomes. Use
a unique identifier, flush, then poll a bounded read for the expected content:

```ruby
require "securerandom"
require "json"

run_id = SecureRandom.hex(6)
trace_id = nil
Langfuse.observe("sdk-e2e-#{run_id}", input: { run_id: run_id }) do |root|
  trace_id = root.trace_id
  root.update(output: { status: "passed" })
end
Langfuse.force_flush

deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
loop do
  rows = Langfuse.client.list_observations(
    trace_id: trace_id, fields: "core,basic,io"
  ).fetch("data")
  found = rows.any? do |row|
    row["name"] == "sdk-e2e-#{run_id}" && JSON.parse(row.fetch("output"))["status"] == "passed"
  end
  break if found
  raise "Langfuse ingestion timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

  sleep 1
end
```

For asynchronous scores, call `Langfuse.flush_scores` before readback. A synchronous
`create_score!` confirms HTTP acceptance but can still precede read visibility.

## Verify Through the Langfuse CLI

The CLI uses an independent client path. Supply credentials through the environment,
not command arguments:

```bash
langfuse api observations list --trace-id "$TRACE_ID" --fields core,basic,io --json
langfuse api scores list --trace-id "$TRACE_ID" --fields details,subject --json
```

If the CLI is not installed, replace `langfuse` with `npx --yes langfuse-cli@latest`.
It reads `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, and `LANGFUSE_BASE_URL`.
JSON output wraps the API response in `status`, `headers`, and `body`; rows are in
`body.data`. Use `langfuse api __schema` and each action's `--help` for the installed
CLI contract. See the [CLI guide](https://langfuse.com/docs/api-and-data-platform/features/cli)
and [Public API](https://langfuse.com/docs/api-and-data-platform/features/public-api).
