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
- **Type:** Symbol (`:memory` or `:rails`)
- **Default:** `:memory`
- **Description:** Cache storage backend

```ruby
# In-memory cache (default, thread-safe)
config.cache_backend = :memory

# Rails.cache (requires Rails + Redis)
config.cache_backend = :rails
```

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

#### `batch_size`
- **Type:** Integer
- **Default:** `50`
- **Description:** Number of scores to batch before sending to API

```ruby
config.batch_size = 100  # Larger batches for high-volume scoring
```

Used by scoring API. See [SCORING.md](SCORING.md).

#### `flush_interval`
- **Type:** Integer (seconds)
- **Default:** `10`
- **Description:** Maximum time to wait before flushing batched scores

```ruby
config.flush_interval = 5  # Flush more frequently
```

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
- **Status:** Not yet implemented (placeholder)
- **Description:** Future: enable async background processing for traces

```ruby
config.tracing_async = true  # Placeholder - no effect currently
```

**Current Behavior:** All trace operations are synchronous with OpenTelemetry export. This option is reserved for future async job processing.

#### `job_queue` ⚠️ Experimental
- **Type:** Symbol
- **Default:** `:default`
- **Status:** Not yet implemented (placeholder)
- **Description:** Future: ActiveJob queue name for async tracing

```ruby
config.job_queue = :langfuse  # Placeholder - no effect currently
```

**Current Behavior:** No ActiveJob integration yet. Reserved for future implementation.

## Environment Variables

The SDK does not automatically read environment variables. You must explicitly pass them in configuration:

```ruby
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  config.base_url = ENV['LANGFUSE_BASE_URL'] || 'https://cloud.langfuse.com'
end
```

### Recommended Variable Names

```bash
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
LANGFUSE_BASE_URL=https://cloud.langfuse.com  # Optional
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
- `cache_backend` must be `:memory` or `:rails`
- If `:rails`, Rails must be defined

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
