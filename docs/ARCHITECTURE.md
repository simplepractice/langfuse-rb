# Architecture

The SDK exposes a flat `Langfuse::Client` API and module-level tracing and score
helpers. `Langfuse.configure` stores global configuration; clients and tracing
resources initialize lazily. The SDK requires Ruby 3.2+ and has no Rails dependency.

## Component Ownership

| Component | Responsibility |
| --- | --- |
| `Config` | Environment defaults, client validation, and separate tracing validation. |
| `Client` | Public API, typed response wrappers, cache selection, and experiment entry points. |
| `ApiClient` / `ReadApi` | Authenticated Faraday requests, response handling, and current read endpoints. |
| `PromptCacheCoordinator` | Prompt selection, cache reads/writes, refresh, and invalidation. |
| `PromptCache` / `RailsCacheAdapter` | Process-local memory or the application's Rails cache store. |
| `StaleWhileRevalidate` | Background refresh scheduling and per-key coordination. |
| `TextPromptClient` / `ChatPromptClient` | Mustache compilation and chat message placeholders. |
| Observation classes | Wrap OpenTelemetry spans and translate SDK updates into attributes. |
| `OtelSetup` | Internal provider, sampler, batch processor, and exporter lifecycle. |
| `SpanProcessor` / `AppRootTracking` | Attribute propagation, export filtering, and logical root selection. |
| `Masking` / `MaskingExporter` | Payload masking and export-copy attribute patches. |
| `ScoreClient` / `PendingScoreQueue` | Score validation, payload snapshots, bounded queue, batching, and acknowledgment. |
| `ExperimentRunner` | Task execution, evaluator results, dataset links, and experiment attribution. |
| `ForkSafety` / `ExitHook` | Child-process resource reset and normal-exit shutdown attempt. |

## Data Paths

- Prompts: `Client` → `ApiClient` → `PromptCacheCoordinator` → cache or HTTP → typed
  prompt client. Compilation happens locally. Cache keys select templates, not variables.
- Traces: observation → OpenTelemetry span → Langfuse processor → batch processor →
  optional export masking → exporter. The default OTLP exporter posts to
  `/api/public/otel/v1/traces` with `x-langfuse-ingestion-version: 4`.
- Scores: validate and snapshot → bounded queue → `ApiClient.send_score_batch` →
  `POST /api/public/scores`. Synchronous scores use the same transport without the queue.
- Reads: `Client` → `ReadApi` → bounded observations, metrics, or scores request →
  string-keyed response hash.

## Invariants

Keep public client operations flat. Internal components may own separate concerns,
but callers should not need manager objects to fetch prompts or create scores.

Prompt cache synchronization must not imply stronger consistency than the backend
provides. Memory caches are process-local; Rails sharing and atomic locks depend on
its cache store. See [Caching](CACHING.md) for cold-miss and invalidation limits.

Langfuse owns its internal tracer provider and configured exporter. It does not
install a global provider or propagator implicitly. Root classification can defer
completed spans until active ancestors finish. Export-stage masking modifies only
the Langfuse export copy. See [Tracing](TRACING.md).

Pending scores include in-flight batches. Remove them only after a terminal delivery
outcome; preserve IDs and timestamps across retries. Queue capacity and request byte
limits must remain bounded. See [Scoring](SCORING.md).

Normal exit attempts delivery but does not provide durable storage. A forked child
must not resend its parent's pending scores. Configuration reset shuts down the
existing lifecycle; application-owned global provider references must be reinstalled.
