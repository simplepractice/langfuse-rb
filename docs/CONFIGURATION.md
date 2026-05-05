# Configuration Reference

Complete guide to configuring the Langfuse Ruby SDK.

## Configuration Pattern

The SDK uses global configuration via `Langfuse.configure`:

```ruby
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  # ... additional options
end
```

Call this once at application startup (Rails initializer, boot script, etc.).

## Tracing Ownership

This is the part people get wrong.

- `Langfuse.configure` stores configuration only.
- Module-level tracing initializes lazily on first use.
- Langfuse tracing is isolated by default.
- `Langfuse.tracer_provider` is the explicit seam for installing Langfuse as the global OpenTelemetry provider.
- `should_export_span` only runs on spans handled by Langfuse's provider.
- Filtering is not the fix for ambient-span overcapture. Isolation is.
- Langfuse does not auto-configure a second OpenTelemetry backend or any multi-export pipeline for you.

Default isolated setup:

```ruby
Langfuse.configure do |config|
  config.public_key = ENV["LANGFUSE_PUBLIC_KEY"]
  config.secret_key = ENV["LANGFUSE_SECRET_KEY"]
end
```

Explicit global install:

```ruby
Langfuse.configure do |config|
  config.public_key = ENV["LANGFUSE_PUBLIC_KEY"]
  config.secret_key = ENV["LANGFUSE_SECRET_KEY"]
end

OpenTelemetry.tracer_provider = Langfuse.tracer_provider
```

If you also want propagation or another OpenTelemetry backend, configure those in your application. Langfuse does not infer or install them.

## All Configuration Options

### Required

#### `public_key`

- **Type:** String
- **Required:** Yes
- **Description:** Your Langfuse public API key (starts with `pk-lf-`)

```ruby
config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
```

#### `secret_key`

- **Type:** String
- **Required:** Yes
- **Description:** Your Langfuse secret API key (starts with `sk-lf-`)

```ruby
config.secret_key = ENV['LANGFUSE_SECRET_KEY']
```

### Optional

#### `base_url`

- **Type:** String
- **Default:** `"https://cloud.langfuse.com"`
- **Description:** Langfuse API endpoint (use custom for self-hosted)

```ruby
config.base_url = "https://your-instance.langfuse.com"
```

#### `timeout`

- **Type:** Integer (seconds)
- **Default:** `5`
- **Description:** HTTP request timeout for API calls

```ruby
config.timeout = 10  # Increase for slow networks
```

#### `cache_ttl`

- **Type:** Integer (seconds)
- **Default:** `60`
- **Description:** How long to cache fetched prompts

```ruby
config.cache_ttl = 300  # Cache for 5 minutes
```

See [CACHING.md](CACHING.md) for cache strategies.

#### `cache_max_size`

- **Type:** Integer (entries)
- **Default:** `1000`
- **Description:** Maximum number of prompts to cache

```ruby
config.cache_max_size = 5000  # Large prompt library
```

#### `cache_backend`

- **Type:** Symbol (`:memory`, `:rails`, or `:auto`)
- **Default:** `:memory`
- **Description:** Cache storage backend

```ruby
# In-memory cache (default, thread-safe)
config.cache_backend = :memory

# Rails.cache (requires Rails + Redis)
config.cache_backend = :rails

# Opt in to automatic Rails.cache detection
config.cache_backend = :auto
```

`:auto` chooses `:rails` only when Rails and `Rails.cache` are present; otherwise it falls back to `:memory`. The gem default stays `:memory`.

**Requirements for `:rails` backend:**

- Rails must be defined
- `Rails.cache` must be configured (typically Redis)

See [CACHING.md](CACHING.md) for backend comparison.

#### `cache_lock_timeout`

- **Type:** Integer (seconds)
- **Default:** `10`
- **Description:** Timeout for cache stampede protection locks

```ruby
config.cache_lock_timeout = 5  # Faster timeout for high-traffic apps
```

See [CACHING.md](CACHING.md#stampede-protection) for details.

#### `cache_stale_while_revalidate`

- **Type:** Boolean
- **Default:** `false`
- **Description:** Advisory SWR intent flag (effective SWR behavior is controlled by `cache_stale_ttl`)

```ruby
config.cache_stale_while_revalidate = true  # Optional intent flag
```

This flag does not independently turn SWR on or off. SWR activates when `cache_stale_ttl > 0`; the flag exists only as an advisory indicator of intent.

**Behavior (driven by `cache_stale_ttl`):**

- `cache_stale_ttl <= 0` (default): Cache expires at TTL, next request waits for API (~100ms)
- `cache_stale_ttl > 0`: After TTL, serves stale data instantly (~1ms) + refreshes in background

**Important:** To activate SWR, set `cache_stale_ttl` to a positive value (typically equal to `cache_ttl`).

**Compatibility:**

- ✅ Works with `:memory` backend
- ✅ Works with `:rails` backend

See [CACHING.md](CACHING.md#stale-while-revalidate-swr) for detailed usage.

#### `cache_stale_ttl`

- **Type:** Integer (seconds) or `:indefinite` Symbol
- **Default:** `0` (SWR disabled)
- **Description:** Grace period for serving stale data during background refresh
- **Note:** `:indefinite` is automatically normalized to 1000 years (31,536,000,000 seconds) during config initialization

```ruby
config.cache_stale_ttl = 300  # Serve stale data for up to 5 minutes
config.cache_stale_ttl = :indefinite  # Never expire (normalized to 1000 years internally)
```

**How it works:**

- After `cache_ttl` expires, data becomes "stale" but still servable
- Requests return stale data immediately while background refresh occurs
- After `cache_stale_ttl` expires, data becomes "expired" and requires synchronous fetch

**Recommended values:**

- Same as `cache_ttl`: Balanced freshness/latency
- `2x cache_ttl`: More tolerance for API slowdowns
- `:indefinite`: Maximum performance, eventual consistency, high availability

**Important:** When enabling SWR, you should also set `cache_stale_ttl` to a positive value (e.g., same as `cache_ttl`), otherwise stale data expires immediately after the TTL.

See [CACHING.md](CACHING.md#stale-while-revalidate-swr) for examples.

#### `cache_refresh_threads`

- **Type:** Integer
- **Default:** `5`
- **Description:** Number of background threads for stale cache refresh

```ruby
config.cache_refresh_threads = 10  # More threads for high-traffic apps
```

**Thread pool sizing:**

- Small apps (< 25 prompts): 2-3 threads sufficient
- Medium apps (25-100 prompts): 5 threads (default)
- Large apps (> 100 prompts): 10+ threads

**Memory impact:** ~1-2MB per thread pool (negligible)

Only used when SWR is enabled (`cache_stale_ttl > 0`).

#### `prompt_cache_observer`

- **Type:** Callable or `nil`
- **Default:** `nil`
- **Description:** Observer hook for prompt cache events

```ruby
config.prompt_cache_observer = lambda do |event, payload|
  Rails.logger.info(event: event, prompt: payload[:name], status: payload[:cache_status])
end
```

When ActiveSupport is loaded, the SDK also instruments `prompt_cache.langfuse`.

#### `batch_size`

- **Type:** Integer
- **Default:** `50`
- **Description:** Number of scores to batch before sending to API. Also used for OpenTelemetry trace export batching.

```ruby
config.batch_size = 100  # Larger batches for high-volume scoring
```

Used by scoring API and OpenTelemetry tracing export. See [SCORING.md](SCORING.md).

#### `flush_interval`

- **Type:** Integer (seconds)
- **Default:** `10`
- **Description:** Maximum time to wait before flushing batched scores. Also controls OpenTelemetry trace export schedule when tracing is async.

```ruby
config.flush_interval = 5  # Flush more frequently
```

#### `sample_rate`

- **Type:** Float (`0.0..1.0`)
- **Default:** `1.0`
- **Description:** Deterministic sampling rate for traces and trace-linked scores, based on trace ID

```ruby
config.sample_rate = 0.1  # Sample ~10% of traces
```

`0.0` drops all traces, `1.0` preserves current always-on behavior.
Trace-linked scores use the same `sample_rate` decision so the SDK does not create orphaned scores for sampled-out traces.
Session-only and dataset-run-only scores are still sent because they are not tied to a sampled trace.

For Ruby client instances, `sample_rate` is snapshotted when the client is built. Changing `config.sample_rate` later does not update that client's score sampler or the already-initialized trace sampler. Rebuild the client with `Langfuse.reset!` when changing sampling behavior.

#### `logger`

- **Type:** Logger
- **Default:** Auto-detected (`Rails.logger` if Rails present, otherwise `Logger.new($stdout)`)
- **Description:** Logger instance for SDK output

```ruby
# Custom logger
config.logger = Logger.new('log/langfuse.log')
config.logger.level = Logger::DEBUG

# Disable logging
config.logger = Logger.new(IO::NULL)
```

#### `tracing_async` ⚠️ Experimental

- **Type:** Boolean
- **Default:** `true`
- **Status:** Implemented for OpenTelemetry batch scheduling; ActiveJob integration is not implemented
- **Description:** Controls OpenTelemetry export scheduling. When `true`, spans use the configured `flush_interval` schedule. When `false`, spans still use OpenTelemetry's batch processor with a long schedule delay and are typically flushed explicitly at lifecycle boundaries.

```ruby
config.tracing_async = true
```

**Current Behavior:** Uses OpenTelemetry `BatchSpanProcessor` in both modes. Async mode uses `flush_interval` for scheduled export; sync mode uses a 60-second schedule delay and is usually paired with explicit `force_flush` for deterministic delivery timing.

#### `job_queue` ⚠️ Experimental

- **Type:** Symbol
- **Default:** `:default`
- **Status:** Reserved/no-op
- **Description:** Reserved for a future ActiveJob integration. It is kept for configuration compatibility and has no runtime effect today.

```ruby
config.job_queue = :langfuse  # Reserved/no-op today
```

**Current Behavior:** No ActiveJob integration yet. Reserved for future implementation.

#### `environment`

- **Type:** String
- **Default:** `nil` (or `ENV["LANGFUSE_TRACING_ENVIRONMENT"]` if set)
- **Description:** Default tracing environment applied to new traces/observations

```ruby
config.environment = "production"
```

#### `release`

- **Type:** String
- **Default:** `nil` (or `ENV["LANGFUSE_RELEASE"]` / CI commit env if set)
- **Description:** Default release identifier applied to new traces/observations

```ruby
config.release = "2024.1"
```

#### `should_export_span`

- **Type:** `#call` (Proc, Lambda, Method, or any object responding to `call`) or `nil`
- **Default:** `nil` (uses Langfuse's default export filter)
- **Description:** Controls whether an ended span handled by Langfuse's tracer provider is exported to Langfuse

```ruby
config.should_export_span = lambda { |span|
  Langfuse.default_export_span?(span) &&
    span.instrumentation_scope&.name != "my_framework.worker"
}
```

This callback only runs for spans processed by Langfuse's tracer provider. Under the default isolated setup, ambient spans created on some other global OpenTelemetry provider never reach this filter.

If you want shared OpenTelemetry spans to be eligible for this filter, install Langfuse explicitly:

```ruby
OpenTelemetry.tracer_provider = Langfuse.tracer_provider
```

When Langfuse processes a span and no custom filter is configured, default behavior exports:

- Langfuse SDK spans
- Spans with `gen_ai.*` attributes
- Spans from conservative LLM-related instrumentation scopes such as `langsmith.*`, `openinference.*`, and `opentelemetry.instrumentation.anthropic.*`

Composing with `Langfuse.default_export_span?` keeps that allowlist and lets you add tighter exclusions.

Use this callback to narrow a provider path Langfuse already owns. Do not treat it as the fix for default ambient-span overcapture. The isolated default already prevents that problem.

#### `mask`

- **Type:** `#call` (Proc, Lambda, or any object responding to `call`) or `nil`
- **Default:** `nil` (masking disabled)
- **Description:** Mask callable applied to `input`, `output`, and `metadata` fields before they are sent to Langfuse. Receives a `data:` keyword argument containing the raw field value. Must return the masked version. If the callable raises, the field is replaced with a fail-closed fallback string.

```ruby
# Redact all values in hashes, replace scalars
config.mask = lambda { |data:|
  if data.is_a?(Hash)
    data.transform_values { "[REDACTED]" }
  else
    "[REDACTED]"
  end
}
```

See [TRACING.md](TRACING.md#masking) for usage patterns and behavior details.

## Tracing Behavior and OpenTelemetry Ownership

There are three states worth documenting.

### Default Isolated Langfuse Tracing

- `Langfuse.configure` does not mutate `OpenTelemetry.tracer_provider`
- `Langfuse.configure` does not mutate `OpenTelemetry.propagation`
- `Langfuse.observe(...)` uses Langfuse's internal tracer provider once tracing is ready
- if `public_key`, `secret_key`, or `base_url` are missing, module-level tracing falls back to a no-op tracer and logs one warning

### Explicit Global Install with `Langfuse.tracer_provider`

If you want Langfuse to own the global OpenTelemetry provider, install it explicitly:

```ruby
require "opentelemetry/trace/propagation/trace_context"

Langfuse.configure do |config|
  config.public_key = ENV["LANGFUSE_PUBLIC_KEY"]
  config.secret_key = ENV["LANGFUSE_SECRET_KEY"]
end

OpenTelemetry.tracer_provider = Langfuse.tracer_provider
OpenTelemetry.propagation = OpenTelemetry::Trace::Propagation::TraceContext::TextMapPropagator.new
```

That global install is a lifecycle commitment. `Langfuse.shutdown` and `Langfuse.reset!` stop the internal provider. If you reset or reconfigure Langfuse, reinstall the tracer provider and any propagators you want afterward.

### Additional OTel Backends Are Application-Owned

If you want spans in another OpenTelemetry backend as well, configure that pipeline in your application. Langfuse does not auto-install multi-export. That can mean:

- adding processors/exporters to the provider you own
- or managing your own provider pipeline explicitly

After the first successful tracing initialization, these settings require `Langfuse.reset!` before changes take effect:

- `public_key`
- `secret_key`
- `base_url`
- `environment`
- `release`
- `sample_rate`
- `should_export_span`
- `tracing_async`
- `batch_size`
- `flush_interval`

That includes processor tuning. Changing `batch_size` or `flush_interval` after tracing is already live will not rebuild the exporter pipeline until reset.

The singleton client follows the same rule for score sampling: once `Langfuse.client` has been built, changing `sample_rate` on `Langfuse.configuration` does not change that client's trace-linked score sampling. Call `Langfuse.reset!`, configure again, and then rebuild the client.

Performance note for `should_export_span`:

- It runs synchronously on every ended span in the application thread
- Keep it allocation-light, non-blocking, and free of network/database calls

## Environment Variables

The SDK automatically reads these environment variables as defaults when no explicit value is configured:

- `LANGFUSE_PUBLIC_KEY` — public API key
- `LANGFUSE_SECRET_KEY` — secret API key
- `LANGFUSE_BASE_URL` — API endpoint (defaults to `https://cloud.langfuse.com`)
- `LANGFUSE_TRACING_ENVIRONMENT` — default trace environment
- `LANGFUSE_RELEASE` — default release identifier (falls back to common CI commit envs if present)
- `LANGFUSE_SAMPLE_RATE` — trace sampling rate (`0.0..1.0`, defaults to `1.0`)

Explicit configuration always takes precedence:

```ruby
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']   # redundant, already auto-read
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']   # redundant, already auto-read
  config.base_url = "https://custom.langfuse.com"  # overrides env var
end
```

### Recommended Variable Names

```bash
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
LANGFUSE_BASE_URL=https://cloud.langfuse.com  # Optional
LANGFUSE_SAMPLE_RATE=0.25                     # Optional
```

## Rails-Specific Configuration

### Using Rails Credentials

Recommended for production:

```ruby
# config/initializers/langfuse.rb
Langfuse.configure do |config|
  config.public_key = Rails.application.credentials.dig(:langfuse, :public_key)
  config.secret_key = Rails.application.credentials.dig(:langfuse, :secret_key)
  config.cache_backend = :rails
end
```

Edit credentials:

```bash
rails credentials:edit
```

Add:

```yaml
langfuse:
  public_key: pk-lf-...
  secret_key: sk-lf-...
```

### Using Environment Variables

For development/staging:

```ruby
# config/initializers/langfuse.rb
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  config.cache_backend = :rails
end
```

`.env` (via dotenv gem):

```bash
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
```

### Rails Cache Backend

When using `cache_backend: :rails`:

```ruby
# config/environments/production.rb
config.cache_store = :redis_cache_store, { url: ENV['REDIS_URL'] }
```

**Advantages:**

- Shared cache across processes (Puma workers, Sidekiq)
- Persistent across deploys
- Built-in Rails instrumentation

**Disadvantages:**

- Requires Redis dependency
- Slightly slower than in-memory

See [CACHING.md](CACHING.md) for performance comparison.

## Configuration by Environment

### Development

```ruby
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  config.cache_ttl = 30  # Short TTL for rapid prompt iteration
  config.logger.level = Logger::DEBUG
end
```

### Production

```ruby
Langfuse.configure do |config|
  config.public_key = Rails.application.credentials.dig(:langfuse, :public_key)
  config.secret_key = Rails.application.credentials.dig(:langfuse, :secret_key)
  config.cache_ttl = 300  # Longer TTL for stability
  config.cache_backend = :rails  # Shared cache
  config.cache_stale_while_revalidate = true  # Advisory intent flag (SWR activates via cache_stale_ttl > 0)
  config.cache_stale_ttl = 300  # Activates SWR
  config.timeout = 10  # Handle network variability
  config.logger = Rails.logger
end
```

### Test

```ruby
# spec/rails_helper.rb or spec/spec_helper.rb
RSpec.configure do |config|
  config.before do
    Langfuse.reset!  # Clear configuration and caches
  end
end

# Or configure once for all tests
Langfuse.configure do |config|
  config.public_key = 'pk-lf-test'
  config.secret_key = 'sk-lf-test'
  config.cache_backend = :memory  # Isolated per-process cache
  config.cache_stale_ttl = 0      # Disable SWR for predictable tests
end
```

See [RAILS.md](RAILS.md#testing) for testing patterns.

## Validation

The SDK validates configuration when you call `Langfuse.client`:

```ruby
Langfuse.configure do |config|
  # Missing keys!
end

Langfuse.client
# => Raises Langfuse::ConfigurationError: "public_key is required"
```

Validation rules:

- `public_key` must be present
- `secret_key` must be present
- `cache_backend` must be `:memory`, `:rails`, or `:auto`
- If `:rails` is selected, or `:auto` resolves to `:rails`, Rails and `Rails.cache` must be available
- `prompt_cache_observer` must respond to `#call` (if set)
- `should_export_span` must respond to `#call` (if set)
- `mask` must respond to `#call` (if set)

## Accessing Current Configuration

```ruby
Langfuse.configure do |config|
  config.public_key = 'pk-lf-...'
  config.cache_ttl = 120
end

# Later...
config = Langfuse.configuration
puts config.public_key  # => "pk-lf-..."
puts config.cache_ttl   # => 120
```

## Resetting Configuration

Useful in tests or when reinitializing:

```ruby
Langfuse.reset!  # Clears config, caches, and client instance
```

After `reset!`, you must call `configure` again before using the client.

## See Also

- [GETTING_STARTED.md](GETTING_STARTED.md) - Initial setup walkthrough
- [CACHING.md](CACHING.md) - Cache backend details and strategies
- [RAILS.md](RAILS.md) - Rails-specific patterns
- [ERROR_HANDLING.md](ERROR_HANDLING.md) - Configuration errors
