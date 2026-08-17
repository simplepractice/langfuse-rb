# Data Access and Verification

Use the read APIs to examine stored Langfuse data.
You can also use them for bounded exports and ingestion verification.
These methods return a Langfuse response envelope, not model objects.

## Choose the Right Read

| Need | SDK method | Langfuse endpoint |
| --- | --- | --- |
| Individual spans, generations, or events | `client.list_observations` | `GET /api/public/v2/observations` |
| Aggregated volume, latency, token, cost, or score data | `client.query_metrics` | `GET /api/public/v2/metrics` |
| Individual typed scores | `client.list_scores` | `GET /api/public/v3/scores` |
| Legacy trace objects | `client.list_traces` / `client.get_trace` | Legacy trace API |

Use observations to traverse current traces.
Use metrics to calculate an aggregate on the server.
Do not download raw rows to calculate an aggregate.

The v2 observations and metrics APIs require Langfuse Cloud or self-hosted Langfuse v4.
The SDK sends the v4 ingestion header.
Thus, new SDK traces do not have the legacy ingestion delay.

## Read Observations

Broad observation reads must include both time bounds. A trace-specific read is already bounded:

```ruby
page = Langfuse.client.list_observations(
  trace_id: trace_id,
  fields: "core,basic,io,model,usage,prompt"
)

page.fetch("data").each do |observation|
  puts "#{observation['type']} #{observation['name']}"
end
```

For project-level queries, pass an inclusive start and exclusive end:

```ruby
page = Langfuse.client.list_observations(
  from_start_time: Time.now.utc - 3600,
  to_start_time: Time.now.utc,
  type: "GENERATION",
  environment: ["production"],
  fields: "core,basic,model,usage",
  limit: 100
)
```

Without `fields`, Langfuse returns only `core` and `basic`.
Request other field groups only when they are necessary.

### Cursor Pagination

Pass the cursor from `meta.cursor` into the same query:

```ruby
rows = []
cursor = nil

loop do
  page = Langfuse.client.list_observations(
    from_start_time: window_start,
    to_start_time: window_end,
    fields: "core,basic",
    limit: 1_000,
    cursor: cursor
  )

  rows.concat(page.fetch("data"))
  cursor = page.dig("meta", "cursor")
  break unless cursor
end
```

Keep the filters and time bounds unchanged between pages.

### Logical Roots

Use `is_root_observation: true` to select application entry points.
A logical root can have a physical parent.
This condition occurs when an upstream or filtered OpenTelemetry span exists.
Use `parent_observation_id` only when you need the physical tree relationship.

## Query Metrics

Metrics queries aggregate server-side. This example counts observations for one trace:

```ruby
result = Langfuse.client.query_metrics(
  query: {
    view: "observations",
    metrics: [{ measure: "count", aggregation: "count" }],
    filters: [
      { column: "traceId", operator: "=", value: trace_id, type: "string" }
    ],
    fromTimestamp: (Time.now.utc - 3600).iso8601,
    toTimestamp: (Time.now.utc + 60).iso8601
  }
)

count = result.dig("data", 0, "count_count")
```

The supported views are `observations`, `scores-numeric`, `scores-boolean`, and `scores-categorical`.
Use high-cardinality values such as trace IDs as filters.
Do not use them as grouping dimensions.

## Read Scores

The scores v3 API returns one polymorphic `value` field:

| `dataType` | Ruby value |
| --- | --- |
| `NUMERIC` | Numeric |
| `BOOLEAN` | `true` or `false` |
| `CATEGORICAL` | String |
| `TEXT` | String |
| `CORRECTION` | String |

```ruby
page = Langfuse.client.list_scores(
  trace_id: trace_id,
  data_type: "BOOLEAN,CORRECTION",
  fields: "details,subject",
  limit: 100
)

page.fetch("data").each do |score|
  case score.fetch("dataType")
  when "BOOLEAN"
    puts score.fetch("value") ? "passed" : "failed"
  when "CORRECTION"
    puts score.fetch("value")
  end
end
```

Score pages also use `meta.cursor`. Keep the original filters when requesting the next page.

## Verify an SDK Write End to End

A reliable verification separates three claims:

1. The SDK accepted the operation.
2. The SDK exporter or HTTP client completed delivery.
3. An independent API read found the persisted backend record.

Use unique names or IDs so a previous run cannot satisfy the assertion:

```ruby
require "securerandom"

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
    trace_id: trace_id,
    fields: "core,basic,io"
  ).fetch("data")

  break if rows.any? { |row| row["name"] == "sdk-e2e-#{run_id}" }
  raise "Langfuse ingestion timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

  sleep 1
end
```

For asynchronous scores, call `Langfuse.flush_scores` before readback.
`create_score!` is synchronous.
An independent read verifies that the backend stored the expected typed value.

## Verify Through the Langfuse CLI

The CLI provides an independent client path through the same public APIs:

```bash
export LANGFUSE_HOST="${LANGFUSE_BASE_URL:-https://cloud.langfuse.com}"

npx --yes langfuse-cli@latest api observations list \
  --trace-id "$TRACE_ID" \
  --fields core,basic,io \
  --json

npx --yes langfuse-cli@latest api scores list \
  --trace-id "$TRACE_ID" \
  --fields details,subject \
  --json
```

Use `npx --yes langfuse-cli@latest api __schema` to list resources.
Use `<resource> <action> --help` to examine the current contract.

With `--json`, the CLI returns an envelope with `status`, `headers`, and `body`.
Read observations and scores from `body.data`.
For HTTP `429`, wait for the returned retry interval.

Do not print API keys or include them in command arguments. Supply them through the environment.

## See Also

- [TRACING.md](TRACING.md) — create well-structured observations
- [SCORING.md](SCORING.md) — create scores and choose delivery semantics
- [API_REFERENCE.md](API_REFERENCE.md#data-access) — complete read signatures and filters
- [Langfuse Observations API](https://langfuse.com/docs/api-and-data-platform/features/observations-api)
- [Langfuse Metrics API](https://langfuse.com/docs/metrics/features/metrics-api)
- [Langfuse Scores API](https://langfuse.com/docs/api-and-data-platform/features/scores-api)
- [Langfuse CLI](https://langfuse.com/docs/api-and-data-platform/features/cli)
