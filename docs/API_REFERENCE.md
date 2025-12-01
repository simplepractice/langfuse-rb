# API Reference

Complete method reference for the Langfuse Ruby SDK.

## Table of Contents

- [Global Configuration](#global-configuration)
- [Client Access](#client-access)
- [Prompt Management](#prompt-management)
- [Tracing & Observability](#tracing--observability)
- [Scoring](#scoring)
- [Attribute Propagation](#attribute-propagation)
- [Types](#types)
- [Exceptions](#exceptions)
- [Utilities](#utilities)

## Global Configuration

### `Langfuse.configure`

Configure the SDK globally. Call once at application startup.

**Signature:**

```ruby
Langfuse.configure { |config| ... }
```

**Parameters:**

Block receives a configuration object with these properties:

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `public_key` | String | Yes | - | Langfuse public API key |
| `secret_key` | String | Yes | - | Langfuse secret API key |
| `base_url` | String | No | `"https://cloud.langfuse.com"` | API endpoint |
| `timeout` | Integer | No | `5` | HTTP timeout (seconds) |
| `cache_ttl` | Integer | No | `60` | Prompt cache TTL (seconds) |
| `cache_max_size` | Integer | No | `1000` | Max cached prompts |
| `cache_backend` | Symbol | No | `:memory` | `:memory` or `:rails` |
| `cache_lock_timeout` | Integer | No | `10` | Lock timeout (seconds) |
| `batch_size` | Integer | No | `50` | Score batch size |
| `flush_interval` | Integer | No | `10` | Score flush interval (seconds) |
| `logger` | Logger | No | Auto-detected | Logger instance |
| `tracing_async` | Boolean | No | `true` | ⚠️ Experimental (not implemented) |
| `job_queue` | Symbol | No | `:default` | ⚠️ Experimental (not implemented) |

**Example:**

```ruby
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  config.cache_ttl = 300
  config.cache_backend = :rails
end
```

See [CONFIGURATION.md](CONFIGURATION.md) for complete guide.

### `Langfuse.configuration`

Access current configuration.

**Signature:**

```ruby
Langfuse.configuration # => Configuration
```

**Returns:** Configuration object with all settings

**Example:**

```ruby
config = Langfuse.configuration
puts config.cache_ttl  # => 60
```

### `Langfuse.reset!`

Reset configuration, caches, and client instance. Primarily for testing.

**Signature:**

```ruby
Langfuse.reset!
```

**Example:**

```ruby
RSpec.configure do |config|
  config.before { Langfuse.reset! }
end
```

## Client Access

### `Langfuse.client`

Get the global singleton client instance.

**Signature:**

```ruby
Langfuse.client # => Client
```

**Returns:** Client instance

**Raises:** `ConfigurationError` if not configured

**Example:**

```ruby
client = Langfuse.client
prompt = client.get_prompt("greeting")
```

## Prompt Management

### `Client#get_prompt`

Fetch a prompt from Langfuse (with caching).

**Signature:**

```ruby
get_prompt(name, version: nil, label: nil, fallback: nil, type: nil)
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | String | Yes | Prompt name |
| `version` | Integer | No | Specific version (mutually exclusive with `label`) |
| `label` | String | No | Version label (e.g., "production") |
| `fallback` | String | No | Fallback template if not found |
| `type` | Symbol | Conditional | `:text` or `:chat` (required if `fallback` provided) |

**Returns:** `TextPromptClient` or `ChatPromptClient`

**Raises:**
- `NotFoundError` if prompt doesn't exist (unless `fallback` provided)
- `UnauthorizedError` if credentials invalid
- `ApiError` on network/server errors

**Examples:**

```ruby
# Latest version
prompt = client.get_prompt("greeting")

# Specific version
prompt = client.get_prompt("greeting", version: 2)

# By label
prompt = client.get_prompt("greeting", label: "production")

# With fallback
prompt = client.get_prompt("new-prompt",
  fallback: "Hello {{name}}!",
  type: :text
)
```

See [PROMPTS.md](PROMPTS.md) for complete guide.

### `Client#compile_prompt`

Convenience method: fetch and compile in one call.

**Signature:**

```ruby
compile_prompt(name, variables: {}, version: nil, label: nil, fallback: nil, type: nil)
```

**Parameters:**

Same as `get_prompt`, plus:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `variables` | Hash | No | Template variables (symbol or string keys) |

**Returns:** String (text prompts) or Array<Hash> (chat prompts)

**Example:**

```ruby
# Text prompt
message = client.compile_prompt("greeting",
  variables: { name: "Alice" },
  label: "production"
)
# => "Hello Alice!"

# Chat prompt
messages = client.compile_prompt("chat-assistant",
  variables: { topic: "Ruby" }
)
# => [{ role: :system, content: "..." }, { role: :user, content: "..." }]
```

### `Client#list_prompts`

List all prompts in the project.

**Signature:**

```ruby
list_prompts(page: 1, limit: 50)
```

**Parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `page` | Integer | No | `1` | Page number |
| `limit` | Integer | No | `50` | Results per page |

**Returns:** Array of prompt hashes

**Example:**

```ruby
prompts = client.list_prompts
prompts.each do |p|
  puts "#{p['name']} v#{p['version']}"
end
```

### Cache Warming

Cache warming is handled by the `CacheWarmer` class, not directly on the Client.

**Example:**

```ruby
warmer = Langfuse::CacheWarmer.new
result = warmer.warm(['greeting', 'farewell'], labels: { 'greeting' => 'production' })
puts "Warmed: #{result[:success].size}"
puts "Failed: #{result[:failed].size}"
```

See [CACHING.md](CACHING.md#cache-warming) for complete cache warming strategies and the `CacheWarmer` API.

### `TextPromptClient`

Returned by `get_prompt` for text prompts.

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `name` | String | Prompt name |
| `version` | Integer | Version number |
| `labels` | Array<String> | Version labels |
| `tags` | Array<String> | Tags |
| `config` | Hash | Configuration metadata |
| `prompt` | String | Raw template |

**Methods:**

#### `compile`

```ruby
compile(**variables) # => String
```

Compiles template with Mustache variables.

**Example:**

```ruby
prompt = client.get_prompt("greeting")
message = prompt.compile(name: "Alice", time: "morning")
```

### `ChatPromptClient`

Returned by `get_prompt` for chat prompts.

**Properties:** Same as `TextPromptClient`

**Methods:**

#### `compile`

```ruby
compile(**variables) # => Array<Hash>
```

Compiles template, returns array of message hashes.

**Example:**

```ruby
prompt = client.get_prompt("chat-assistant")
messages = prompt.compile(topic: "Ruby", level: "beginner")
# => [
#   { role: :system, content: "..." },
#   { role: :user, content: "..." }
# ]
```

## Tracing & Observability

### `Langfuse.observe`

Create a traced observation (block or stateful mode).

**Signature:**

```ruby
# Block mode (auto-ends)
observe(name, attributes = {}, as_type: :span) { |obs| ... }

# Stateful mode (manual end)
observe(name, attributes = {}, as_type: :span) # => BaseObservation
```

**Parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `name` | String | Yes | - | Operation name |
| `attributes` | Hash | No | `{}` | Initial attributes |
| `as_type` | Symbol | No | `:span` | Observation type |

**Observation Types:**

`:span`, `:generation`, `:event`, `:embedding`, `:agent`, `:tool`, `:chain`, `:retriever`, `:evaluator`, `:guardrail`

**Returns:**
- Block mode: block return value
- Stateful mode: observation instance

**Example:**

```ruby
# Block mode
result = Langfuse.observe("operation", { input: "data" }) do |obs|
  result = perform_work
  obs.update(output: result)
  result
end

# Stateful mode
obs = Langfuse.observe("operation", { input: "data" })
result = perform_work
obs.update(output: result)
obs.end
```

See [TRACING.md](TRACING.md) for complete guide.

### `BaseObservation`

Returned by `observe` in stateful mode or passed to block.

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `id` | String | Observation ID (hex span ID) |
| `trace_id` | String | Trace ID (hex trace ID) |
| `trace_url` | String | URL to Langfuse UI |
| `otel_span` | OpenTelemetry::SDK::Trace::Span | Underlying OTel span |
| `type` | String | Observation type |

**Methods:**

#### `update`

```ruby
update(attributes) # => self
update(**keyword_args) # => self
```

Update observation attributes. Accepts `Types::*Attributes` instance or keyword args.

**Example:**

```ruby
obs.update(
  output: { result: "success" },
  metadata: { duration_ms: 150 },
  level: "DEFAULT"
)
```

#### `update_trace`

```ruby
update_trace(attributes) # => self
update_trace(**keyword_args) # => self
```

Update trace-level attributes.

**Example:**

```ruby
obs.update_trace(
  user_id: "user_123",
  session_id: "session_456",
  tags: ["api", "v1"]
)
```

#### `end`

```ruby
end(end_time: Time.now) # => self
```

End the observation (block mode calls this automatically).

#### `start_observation`

```ruby
# Block mode
start_observation(name, attributes = {}, as_type: :span) { |child| ... }

# Stateful mode
start_observation(name, attributes = {}, as_type: :span) # => BaseObservation
```

Create a child observation.

**Example:**

```ruby
Langfuse.observe("parent") do |parent|
  parent.start_observation("child", { step: 1 }) do |child|
    child.update(output: "child result")
  end
end
```

#### `event`

```ruby
event(name:, input: nil, output: nil, metadata: nil, level: "default") # => self
```

Add a point-in-time event to the observation.

**Example:**

```ruby
obs.event(
  name: "checkpoint",
  input: { step: 2 },
  metadata: { timestamp: Time.now.iso8601 },
  level: "DEFAULT"
)
```

#### Attribute Setters

Direct setters for common attributes:

```ruby
obs.input = { data: "input" }
obs.output = { data: "output" }
obs.metadata = { key: "value" }
obs.level = "ERROR"  # DEBUG, DEFAULT, WARNING, ERROR
```

#### Generation-Specific Methods

Available on observations with `as_type: :generation`:

```ruby
obs.model = "gpt-4"
obs.model_parameters = { temperature: 0.7, max_tokens: 100 }
obs.usage = { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 }
```

Or via `update`:

```ruby
# Using setters (preferred)
obs.model = "gpt-4"
obs.model_parameters = { temperature: 0.7 }
obs.usage = { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 }
obs.completion_start_time = Time.now
obs.cost_details = { total_cost: 0.05 }
obs.prompt = { name: "greeting", version: 1, is_fallback: false }

# Or using update() with usage_details keyword
obs.update(
  model: "gpt-4",
  model_parameters: { temperature: 0.7 },
  usage_details: { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 },
  completion_start_time: Time.now,
  cost_details: { total_cost: 0.05 },
  prompt: { name: "greeting", version: 1, is_fallback: false }
)
```

## Scoring

### `Client#create_score`

Create a score for a trace or observation.

**Signature:**

```ruby
create_score(name:, value:, trace_id: nil, observation_id: nil, comment: nil, metadata: nil, data_type: :numeric)
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | String | Yes | Score name |
| `value` | Numeric/String/Boolean | Yes | Score value |
| `trace_id` | String | No | Trace ID to score |
| `observation_id` | String | No | Observation ID to score |
| `comment` | String | No | Score comment |
| `metadata` | Hash | No | Additional metadata |
| `data_type` | Symbol | No | `:numeric`, `:boolean`, or `:categorical` |

**Note:** Must provide at least one of `trace_id` or `observation_id`.

**Example:**

```ruby
client.create_score(
  name: "quality",
  value: 0.85,
  trace_id: "abc123",
  data_type: :numeric,
  comment: "High quality response"
)
```

### `Client#score_active_observation`

Score the currently active observation (from OTel context).

**Signature:**

```ruby
score_active_observation(name:, value:, data_type: :numeric, comment: nil, metadata: nil)
```

**Example:**

```ruby
Langfuse.observe("operation", as_type: :generation) do
  result = perform_llm_call
  Langfuse.client.score_active_observation(name: "quality", value: 0.9, data_type: :numeric)
  result
end
```

### `Client#score_active_trace`

Score the currently active trace.

**Signature:**

```ruby
score_active_trace(name:, value:, data_type: :numeric, comment: nil, metadata: nil)
```

### `Client#flush_scores`

Immediately flush all queued scores to API.

**Signature:**

```ruby
flush_scores(timeout: 30)
```

**Parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `timeout` | Integer | No | `30` | Flush timeout (seconds) |

**Example:**

```ruby
# Before shutdown
Langfuse.client.flush_scores
```

### Module-Level Scoring

Convenience methods delegating to `Langfuse.client`:

```ruby
Langfuse.create_score(name: "quality", value: 0.85, trace_id: "abc")
Langfuse.score_active_observation(name: "quality", value: 0.9, data_type: :numeric)
Langfuse.score_active_trace(name: "overall", value: 5, data_type: :numeric)
Langfuse.flush_scores
```

See [SCORING.md](SCORING.md) for complete guide.

## Attribute Propagation

### `Langfuse.propagate_attributes`

Propagate attributes to all spans created within the block.

**Signature:**

```ruby
propagate_attributes(user_id: nil, session_id: nil, metadata: nil, version: nil, tags: nil, as_baggage: false) { ... }
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `user_id` | String | No | User identifier (≤200 chars) |
| `session_id` | String | No | Session identifier (≤200 chars) |
| `metadata` | Hash<String, String> | No | Metadata hash |
| `version` | String | No | Version (≤200 chars) |
| `tags` | Array<String> | No | Tags array |
| `as_baggage` | Boolean | No | Propagate across services via OTel baggage |

**Example:**

```ruby
Langfuse.propagate_attributes(
  user_id: "user_123",
  session_id: "session_456",
  metadata: { env: "production" },
  version: "v1.0",
  tags: ["api", "v2"]
) do
  # All observations here inherit these attributes
  Langfuse.observe("operation") { ... }
end
```

## Types

### `Types::SpanAttributes`

```ruby
Types::SpanAttributes.new(
  input: {},
  output: {},
  metadata: {},
  level: "DEFAULT",           # DEBUG, DEFAULT, WARNING, ERROR
  status_message: "",
  version: "",
  environment: ""
)
```

### `Types::GenerationAttributes`

Extends `SpanAttributes` with:

```ruby
Types::GenerationAttributes.new(
  # SpanAttributes fields +
  completion_start_time: Time.now,
  model: "gpt-4",
  model_parameters: { temperature: 0.7 },
  usage_details: { prompt_tokens: 100, completion_tokens: 50 },
  cost_details: { total_cost: 0.05 },
  prompt: { name: "greeting", version: 1, is_fallback: false }
)
```

### `Types::TraceAttributes`

```ruby
Types::TraceAttributes.new(
  name: "trace-name",
  user_id: "user_123",
  session_id: "session_456",
  version: "v1.0",
  release: "2024.1",
  input: {},
  output: {},
  metadata: {},
  tags: ["api", "v1"],
  public: false,
  environment: "production"
)
```

### Other Attribute Types

- `Types::EmbeddingAttributes` - Extends `GenerationAttributes`
- `Types::EventAttributes` - Alias for `SpanAttributes`
- `Types::AgentAttributes` - Alias for `SpanAttributes`
- `Types::ToolAttributes` - Alias for `SpanAttributes`
- `Types::ChainAttributes` - Alias for `SpanAttributes`
- `Types::RetrieverAttributes` - Alias for `SpanAttributes`
- `Types::EvaluatorAttributes` - Alias for `SpanAttributes`
- `Types::GuardrailAttributes` - Alias for `SpanAttributes`

## Exceptions

All exceptions inherit from `Langfuse::Error < StandardError`.

### `Langfuse::ConfigurationError`

Configuration validation errors.

**Raised when:**
- Missing `public_key` or `secret_key`
- Invalid configuration values

### `Langfuse::ApiError`

Base class for API HTTP errors.

**Raised when:**
- Network issues
- Server errors (500, 503)
- Timeouts

### `Langfuse::UnauthorizedError`

Extends `ApiError`. Authentication failures (401).

**Raised when:**
- Invalid API credentials
- Expired keys

### `Langfuse::NotFoundError`

Extends `ApiError`. Resource not found (404).

**Raised when:**
- Prompt doesn't exist
- Invalid version/label

### `Langfuse::CacheWarmingError`

Cache warming operation failed.

**Raised when:**
- One or more prompts failed to warm

See [ERROR_HANDLING.md](ERROR_HANDLING.md) for complete guide.

## Utilities

### `Client#trace_url`

Generate Langfuse UI URL for a trace.

**Signature:**

```ruby
trace_url(trace_id) # => String
```

**Example:**

```ruby
url = client.trace_url("abc123")
# => "https://cloud.langfuse.com/traces/abc123"
```

### `Langfuse.shutdown`

Shutdown the SDK gracefully (flush buffers).

**Signature:**

```ruby
Langfuse.shutdown(timeout: 30)
```

**Parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `timeout` | Integer | No | `30` | Shutdown timeout (seconds) |

**Example:**

```ruby
# Before process exit
Langfuse.shutdown
```

### `Langfuse.force_flush`

Force flush all pending data.

**Signature:**

```ruby
Langfuse.force_flush(timeout: 30)
```

**Example:**

```ruby
Langfuse.force_flush(timeout: 10)
```

## See Also

- [GETTING_STARTED.md](GETTING_STARTED.md) - Quick start guide
- [CONFIGURATION.md](CONFIGURATION.md) - Configuration details
- [PROMPTS.md](PROMPTS.md) - Prompt management
- [TRACING.md](TRACING.md) - Tracing patterns
- [SCORING.md](SCORING.md) - Scoring guide
- [ERROR_HANDLING.md](ERROR_HANDLING.md) - Exception handling
