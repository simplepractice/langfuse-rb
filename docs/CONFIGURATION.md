# Configuration

Configure once at application startup, before creating the client or tracing:

```ruby
require "langfuse"

Langfuse.configure do |config|
  config.public_key = ENV.fetch("LANGFUSE_PUBLIC_KEY")
  config.secret_key = ENV.fetch("LANGFUSE_SECRET_KEY")
  config.environment = "production"
end

client = Langfuse.client
```

Credentials and supported environment variables are read when `Langfuse::Config`
is created. Assignments in the block override those defaults.

## Connection and Logging

| Option | Default | Meaning |
| --- | --- | --- |
| `public_key` | `LANGFUSE_PUBLIC_KEY` | Non-empty String; required for API calls and enabled tracing. |
| `secret_key` | `LANGFUSE_SECRET_KEY` | Non-empty String; required with the public key. |
| `base_url` | `https://cloud.langfuse.com` | Absolute HTTP(S) URL for your Langfuse region or self-hosted instance. |
| `timeout` | `5` | Positive API request timeout in seconds. |
| `logger` | `Rails.logger` when available; otherwise stdout at `WARN` | Must respond to `debug`, `info`, `warn`, and `error`. `nil` disables logging. |

## Prompt Caching

| Option | Default | Meaning |
| --- | --- | --- |
| `cache_backend` | `:memory` | `:memory`, `:rails`, or `:auto`. Auto selects Rails.cache when available. |
| `cache_ttl` | `60` | Fresh lifetime in seconds. `0` disables the client's cache. |
| `cache_max_size` | `1000` | Maximum in-memory entries; does not limit Rails.cache. |
| `cache_lock_timeout` | `10` | Rails cache lock lifetime in seconds. |
| `cache_stale_ttl` | `0` | Additional stale-serving window in seconds. A positive value enables background refresh on stale reads. Accepts `:indefinite` for a finite window of about 1,000 years. |
| `cache_stale_while_revalidate` | `false` | Compatibility setting; does not enable or disable SWR independently of `cache_stale_ttl`. |
| `cache_refresh_threads` | `5` | Background refresh pool size. |
| `prompt_cache_observer` | `nil` | Callable receiving `(event, payload)` for cache events. |

Use positive values for cache capacity, lock timeout, and refresh threads.
TTL values must be non-negative. Use integer counts for entries and threads.
The Rails backend requires `Rails.cache` to exist when the client is built;
shared caching depends on the configured store, not on Rails alone.
See [Caching](CACHING.md) for refresh, invalidation, and backend behavior.

## Tracing and Scoring

| Option | Default | Meaning |
| --- | --- | --- |
| `tracing_enabled` | `true` | Boolean switch for both tracing and scoring. |
| `environment` | `nil` | Default environment for observations and scores. |
| `release` | `nil` or detected CI commit | Release attached to observations. |
| `sample_rate` | `1.0` | Deterministic trace-ID sampling in `0.0..1.0`; also applies to trace-linked scores. |
| `batch_size` | `50` | Positive Integer: score flush threshold and maximum OpenTelemetry export batch size. Score requests also enforce the [API limits](SCORING.md#batching-behavior). |
| `flush_interval` | `10` | Positive number of seconds between score flushes and scheduled trace exports. |
| `score_queue_capacity` | `100_000` | Positive Integer: maximum pending asynchronous scores, including in-flight batches. A full queue drops the new score. |
| `tracing_async` | `true` | Uses `flush_interval` for trace scheduling. `false` still uses a batch processor, with a 60-second schedule; it does not make tracing synchronous. |
| `job_queue` | `:default` | Reserved compatibility setting with no runtime effect. |
| `skills` | `nil` | Catalog such as `{ available: [{ name: "search", version: 1 }] }`; attached only inside opted-in scopes. See [Skill Availability](TRACING.md#skill-availability). |
| `should_export_span` | `nil` | Callable receiving an ended span; replaces the default export filter. |
| `mask` | `nil` | Callable receiving `data:` for Langfuse-created input, output, and metadata. |
| `mask_otel_spans` | `nil` | Callable receiving `params:` for export-stage attribute masking, including third-party spans. |
| `span_exporter` | `nil` | Custom OpenTelemetry exporter; otherwise Langfuse uses OTLP. |
| `metrics_reporter` | `nil` | Custom OpenTelemetry metrics reporter; otherwise metrics are discarded. |

### Runtime Modes

| Setting | Traces | Scores | Prompt and read APIs |
| --- | --- | --- | --- |
| Default | Enabled | Enabled | Available |
| `tracing_enabled = false` | Disabled | No-op; `create_score!` returns `nil` | Available with valid configuration and credentials |
| `OTEL_SDK_DISABLED=true` | Disabled | Enabled | Available |

`tracing_enabled` changes apply to the initialized SDK. Buffered spans are dropped
while it is false. Environment variables are read when configuration is created.

### Tracing Ownership

Langfuse initializes its internal OpenTelemetry provider lazily. It does not replace
`OpenTelemetry.tracer_provider` or `OpenTelemetry.propagation`. Use the explicit
[global installation](TRACING.md#opentelemetry-integration) when you want other
instrumentation to use Langfuse's provider.

Set pipeline options before tracing starts. Changing credentials, host, environment,
release, sampling, filtering, export-stage masking, exporter, metrics reporter, or
batch scheduling requires `Langfuse.reset!` and configuration of the new lifecycle.
Score sampling is also captured when the client is built. Reinstall any global
provider reference after a reset; the previous provider has been shut down.

### Export Filtering and Masking

`should_export_span` runs once after each span ends, only for spans processed by
Langfuse's provider. Combine it with `Langfuse.default_export_span?(span)` to retain
the default allowlist. Keep the callback fast and free of network calls.

`mask` transforms input, output, and metadata passed when creating or updating
observations and traces. It does not mask metadata passed through `propagate_attributes`
or arbitrary OpenTelemetry attributes. `mask_otel_spans` receives an immutable
export-batch snapshot and returns attribute patches for the Langfuse export only.
Other exporters receive their original spans. See [Masking](TRACING.md#masking) for
examples, execution constraints, result types, and failure behavior.

### Custom Exporters

A `span_exporter` must implement `export`, `force_flush`, and `shutdown` using the
OpenTelemetry exporter interface. Langfuse retains its normal sampling, filtering,
masking, and batch processing. Its provider owns the exporter lifecycle and shuts
it down on `Langfuse.shutdown` or `Langfuse.reset!`; supply a new exporter afterward.
See [Testing](TESTING.md) for an in-memory example.

### Metrics Reporter

A reporter must implement:

```ruby
add_to_counter(metric, increment: 1, labels: {})
record_value(metric, value:, labels: {})
observe_value(metric, value:, labels: {})
```

OpenTelemetry owns the metric names and labels. Reporter methods may run on
application or export threads and must be fast, thread-safe, and nonblocking.
Reporter failures log a warning without stopping export. The application owns
reporter cleanup: shut down Langfuse first, then flush or close the reporter.

## Environment Variables

| Variable | Configuration equivalent |
| --- | --- |
| `LANGFUSE_PUBLIC_KEY` | `public_key` |
| `LANGFUSE_SECRET_KEY` | `secret_key` |
| `LANGFUSE_BASE_URL` | `base_url` |
| `LANGFUSE_TIMEOUT` | `timeout`; integer seconds |
| `LANGFUSE_FLUSH_AT` | `batch_size`; Integer |
| `LANGFUSE_FLUSH_INTERVAL` | `flush_interval`; numeric seconds |
| `LANGFUSE_TRACING_ENABLED` | `tracing_enabled`; case-insensitive `true` or `false` |
| `LANGFUSE_TRACING_ENVIRONMENT` | `environment` |
| `LANGFUSE_RELEASE` | `release`; otherwise uses the first populated entry in `Config::COMMON_RELEASE_ENV_KEYS` |
| `LANGFUSE_SAMPLE_RATE` | `sample_rate` |
| `LANGFUSE_DEBUG=true` | stdout logger at `DEBUG` |
| `OTEL_SDK_DISABLED=true` | Disables trace export only |

## Validation and Reset

`Langfuse.client` validates client settings. `Langfuse.configured?` performs a local,
non-raising readiness check; it does not authenticate or verify delivery.
`Langfuse::Config#valid?` checks the full client configuration. Tracing validates
its pipeline separately; module-level tracing uses a no-op tracer if configuration
is invalid, while `Langfuse.tracer_provider` raises `ConfigurationError`.

With telemetry disabled, a client can be built without credentials. Prompt and
read methods still require valid client configuration when called.

`Langfuse.reset!` shuts down the existing client and provider and clears their
configuration. The next access creates configuration from the environment again.
Reapply any explicit settings before use.

## Forking Servers and Workers

After Ruby `fork`, the child starts with a new score queue and synchronization
state. Parent-owned queued scores are discarded in the child to prevent duplicate
submission. In-memory prompt values remain available. OpenTelemetry and the
background refresh pool reset their own worker state. Each process owns its shutdown.

## Process Exit

Normal process exit attempts to flush pending traces and scores automatically.
Use `Langfuse.shutdown` for an earlier shutdown boundary. It disables the pending
exit callback. Abrupt termination such as `SIGKILL` cannot flush, and API failure
can still prevent delivery during shutdown.

Use `Langfuse.force_flush` and `Langfuse.flush_scores` before an immediate readback;
backend visibility can lag HTTP acceptance. See [Data Access](DATA_ACCESS.md).
