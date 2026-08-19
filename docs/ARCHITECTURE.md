# Architecture Overview

This document describes the Langfuse Ruby SDK architecture and its main design decisions.

## Table of Contents

- [Design Philosophy](#design-philosophy)
- [Core Components](#core-components)
- [Key Design Decisions](#key-design-decisions)
- [Data Flow](#data-flow)
- [Technology Choices](#technology-choices)

## Design Philosophy

The Langfuse Ruby SDK follows these core principles:

### 1. LaunchDarkly-Inspired API

Put all public methods on `Client`.
Do not use nested managers:

```ruby
# Correct: flat API
client.get_prompt("name")
client.compile_prompt("name", variables: {})

# Incorrect: nested managers
client.prompts.get("name")
client.prompts.compile("name")
```

This API reduces the number of classes that a user must know.
It also gives direct IDE autocomplete results.

### 2. Rails-Friendly

Use one global configuration block in Rails:

```ruby
# config/initializers/langfuse.rb
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
end

# Use the configured client
client = Langfuse.client
```

### 3. Ruby Conventions

- **snake_case** for methods: `get_prompt`, not `getPrompt`
- **Symbol keys** in hashes: `{ role: :user }`
- **Keyword arguments**: `get_prompt(name, version: 2)`
- **Blocks** for configuration and scoping

### 4. Minimal Dependencies

Add a dependency only when the SDK requires it:

- **Faraday** - HTTP client
- **Mustache** - Logic-free variable templates
- **OpenTelemetry** - Distributed tracing

The SDK has no Rails dependency.
It operates in any supported Ruby project.

### 5. Thread-Safe by Default

SDK components use these synchronization mechanisms:

- `PromptCache` uses Monitor
- `RailsCacheAdapter` uses Redis atomic operations
- `ScoreClient` uses a bounded `PendingScoreQueue` and mutexes for ordered batching
- OpenTelemetry handles context propagation

## Core Components

### 1. Configuration (`Langfuse::Config`)

Central configuration object with validation:

```ruby
config = Langfuse::Config.new do |c|
  c.public_key = "pk_..."
  c.secret_key = "sk_..."
  c.cache_ttl = 60
end
```

**Responsibilities:**
- Store SDK configuration
- Validate required settings
- Read supported environment defaults
- Control tracing and scoring independently from the OpenTelemetry trace switch

### 2. HTTP Client (`Langfuse::ApiClient`)

HTTP layer with Faraday:

```ruby
api_client = Langfuse::ApiClient.new(
  public_key: config.public_key,
  secret_key: config.secret_key,
  base_url: config.base_url,
  timeout: config.timeout,
  logger: config.logger,
  cache: cache
)
prompt_data = api_client.get_prompt("name")
```

**Responsibilities:**
- HTTP requests to Langfuse API
- Authentication (Basic Auth)
- Retry logic with exponential backoff
- Cache integration

### 3. Prompt Clients

#### TextPromptClient

Use this client for string templates:

```ruby
prompt = TextPromptClient.new(api_response)
result = prompt.compile(name: "Alice")  # => "Hello Alice!"
```

#### ChatPromptClient

For chat/completion prompts:

```ruby
prompt = ChatPromptClient.new(api_response)
messages = prompt.compile(user: "Alice")
# => [{ role: :system, content: "..." }, { role: :user, content: "..." }]
```

**Responsibilities:**
- Wrap API response data
- Compile prompts with Mustache
- Provide metadata access

### 4. Caching Layer

Two backends with same interface:

#### PromptCache (In-Memory)

```ruby
cache = Langfuse::PromptCache.new(ttl: 60, max_size: 1000)
cache.set(key, value)
cached = cache.get(key)
```

**Features:**
- Thread-safe with Monitor
- TTL expiration
- Bounded expiration-ordered eviction

#### RailsCacheAdapter (Distributed)

```ruby
adapter = Langfuse::RailsCacheAdapter.new(ttl: 60)
adapter.set(key, value)
cached = adapter.get(key)
```

**Features:**
- Wraps Rails.cache (Redis/Memcached)
- Distributed locks for stampede protection
- Exponential backoff

### 5. Main Client (`Langfuse::Client`)

User-facing API:

```ruby
client = Langfuse::Client.new(config)
prompt = client.get_prompt("name")
text = client.compile_prompt("name", variables: { name: "Alice" })
```

**Responsibilities:**
- Factory for prompt clients
- Cache backend selection
- High-level API methods
- Score creation and management (delegates to ScoreClient)
- Current observation, metric, and score reads (delegates through ReadApi)

### 6. Tracing Layer (OpenTelemetry-based)

#### Observations System

The SDK uses an observation-based model where all tracing operations create "observations" - wrappers around OpenTelemetry spans with Langfuse-specific functionality.

**Observation Types:**
- **Span** - General-purpose operation tracking
- **Generation** - LLM calls (OpenAI, Anthropic, etc.)
- **Event** - Point-in-time occurrences
- **Embedding** - Vector embedding generation
- **Agent** - Agent-based workflows
- **Tool** - External tool/API calls
- **Chain** - Multi-step workflows
- **Retriever** - Document retrieval operations
- **Evaluator** - Quality assessment operations
- **Guardrail** - Safety/compliance checks

**Block-based API (auto-ends):**

```ruby
Langfuse.observe("user-request") do |span|
  span.start_observation("llm-call", { model: "gpt-4" }, as_type: :generation) do |gen|
    gen.output = "Response"
    gen.usage_details = { prompt_tokens: 10, completion_tokens: 20 }
  end
end
```

**Stateful API (manual end):**

```ruby
span = Langfuse.start_observation("user-request")
gen = span.start_observation("llm-call", { model: "gpt-4" }, as_type: :generation)
gen.output = "Response"
gen.usage_details = { prompt_tokens: 10, completion_tokens: 20 }
gen.end
span.end
```

**Key Components:**

- **BaseObservation** - Base class for all observation types
- **OtelSetup** - Initializes OpenTelemetry SDK with OTLP exporter
- **SpanProcessor** - Propagates trace-level attributes to child spans
- **OtelAttributes** - Converts Langfuse attributes to OpenTelemetry format
- **MaskingExporter** - Applies export-stage patches to Langfuse's span copy
- **AppRootTracking** - Preserves logical application roots across filtered parents
- **ForkSafety** - Rebuilds SDK-owned background state in child processes
- **ExitHook** - Flushes pending tracing and scores during normal process exit

**Responsibilities:**
- Wrap OpenTelemetry spans with Langfuse-specific functionality
- Convert OTel spans → Langfuse ingestion format via OTLP
- Handle parent-child relationships
- Batch export for efficiency

### 7. Score Client (`Langfuse::ScoreClient`)

Handles creation and batching of score events:

```ruby
score_client = ScoreClient.new(api_client: api_client, config: config)
score_client.create(name: "quality", value: 0.85, trace_id: "abc123...")
```

**Features:**
- Bounded, ordered asynchronous queue
- Synchronous score creation through the Scores API
- Automatic batching by count, payload size, and flush interval
- Background flush timer thread
- Integration with OpenTelemetry spans (extracts trace_id/observation_id)

**Responsibilities:**
- Queue score events for batching
- Reject or drop work at documented boundaries instead of allowing unbounded memory growth
- Extract trace/observation IDs from active OTel spans
- Batch and send scores to ingestion API
- Handle graceful shutdown and flush

### 8. Attribute Propagation (`Langfuse::Propagation`)

Propagates trace-level attributes (user_id, session_id, metadata, tags) to all child spans:

```ruby
Langfuse.propagate_attributes(user_id: "user_123", session_id: "session_abc") do
  Langfuse.observe("operation") do |span|
    # span automatically has user_id and session_id
    span.start_observation("child") do |child|
      # child also inherits user_id and session_id
    end
  end
end
```

**Responsibilities:**
- Set attributes on current span
- Propagate attributes to all new child spans via SpanProcessor
- Support cross-service propagation via OpenTelemetry baggage

## Key Design Decisions

### 1. OpenTelemetry Foundation for Tracing

**Decision:** Build tracing on OpenTelemetry instead of custom implementation

**Reasons:**
- OpenTelemetry is a Cloud Native Computing Foundation standard.
- It supports W3C Trace Context when the application configures propagation.
- It can integrate with application performance monitoring tools.
- It provides context and propagation components.

**Benefits:**
- The application can use one trace context across services.
- The application can install an OpenTelemetry propagator.

**Limits:**
- OpenTelemetry adds approximately 10 gem dependencies.
- OpenTelemetry configuration adds setup steps.

### 2. Dual Cache Backend

**Decision:** Support both in-memory and Rails.cache backends

**Reasons:**
- The in-memory cache applies to scripts and single-process applications.
- `Rails.cache` can share prompt data across processes.

**Benefits:**
- Applications can select a cache for their process model.
- The default cache does not require an external service.

**Limits:**
- The SDK must maintain two cache implementations.
- Tests must cover both cache implementations.

### 3. Stampede Protection via Distributed Locks

**Decision:** Use Redis atomic operations for stampede protection

**Reasons:**
- A distributed lock prevents concurrent cache misses from producing duplicate API calls.
- The `Rails.cache` backend can coordinate many application processes.

**Benefits:**
- One process refreshes a stale cache entry.
- Other processes wait for the shared result.
- No additional SDK option is necessary.

**Limits:**
- Distributed locking applies only to the `Rails.cache` backend.
- Waiting processes have additional latency.

### 4. Mustache for Variable Substitution

**Decision:** Use Mustache templating instead of ERB or custom solution

**Reasons:**
- Mustache templates do not execute Ruby code.
- The syntax matches the Langfuse JavaScript SDK.
- Mustache supports nested objects, arrays, and sections.

**Alternatives:**
- ERB can execute Ruby code.
- String interpolation does not support the required template structures.
- A custom parser would duplicate Mustache behavior.

### 5. Flat API Surface

**Decision:** All methods on `Client`, not nested managers

**Reasons:**
- The LaunchDarkly Ruby SDK uses this API shape.
- Direct methods reduce the number of public classes.
- Direct methods give direct IDE autocomplete results.

**Example:**
```ruby
# Correct: flat API
client.get_prompt("name")
client.compile_prompt("name", variables: {})

# Incorrect: nested API
client.prompts.get("name")
client.prompts.compile("name", variables: {})
```

### 6. Global Configuration Singleton

**Decision:** `Langfuse.configure` block pattern with global client

**Reasons:**
- Rails initializers commonly use global configuration blocks.
- Application code does not have to pass a client to each object.
- The singleton uses synchronization.
- Tests can call `Langfuse.reset!`.

**Benefits:**
- Applications use one configuration entry point.
- The configuration shape follows Rails conventions.

**Limit:**
- The singleton is global state.

### 7. Observation-Based Tracing Model

**Decision:** Use unified observation model instead of separate trace/span/generation classes

**Reasons:**
- The model matches the Langfuse JavaScript SDK architecture.
- One `start_observation()` method accepts an `as_type` parameter.
- The API supports all Langfuse observation types.

**Benefits:**
- All observation types use the same API.
- The model can include new observation types.
- The model matches the Langfuse platform.

**Limit:**
- Callers must select the correct `as_type` value.

### 8. OTLP as the Default Export Protocol

**Decision:** Use the OpenTelemetry OTLP exporter by default.
Require explicit exporter injection.

**Reasons:**
- OTLP is an OpenTelemetry protocol.
- The Langfuse server converts OTLP data to the Langfuse format.
- `BatchSpanProcessor` supplies batch export.
- `Config#span_exporter` supplies an explicit test and integration interface.

**Benefits:**
- The SDK uses one export protocol.
- The server owns format conversion.
- An injected exporter uses the normal sampler, filter, enrichment, masking, and batch pipeline.

**Limit:**
- The Langfuse server must support OTLP.

## Data Flow

### Prompt Fetching

```
User Code
  └─> Client.get_prompt("name")
       ├─> Check cache (PromptCache or RailsCacheAdapter)
       │    ├─> Cache HIT: Return cached prompt (~1ms)
       │    └─> Cache MISS: Continue to API
       ├─> ApiClient.get_prompt("name")
       │    ├─> Faraday HTTP request with retry
       │    ├─> Basic Auth header
       │    └─> Parse JSON response
       ├─> Cache response
       └─> Return TextPromptClient or ChatPromptClient
```

### Stampede Protection (Rails.cache only)

```
Cache expires → Multiple processes request same prompt
  └─> Process 1: Acquires distributed lock (Redis)
       ├─> Fetches from API
       ├─> Populates cache
       └─> Releases lock
  └─> Processes 2-N: Wait with exponential backoff
       ├─> 50ms, 100ms, 200ms
       ├─> Read from cache (populated by Process 1)
       └─> Return cached prompt

Result: 1 API call instead of N
```

### LLM Tracing

```
User Code
  └─> Langfuse.observe("query") do |span|
       ├─> Langfuse.start_observation() creates OTel root span
       ├─> BaseObservation wraps OTel span
       └─> span.start_observation("llm-call", { model: "gpt-4" }, as_type: :generation) do |gen|
            ├─> BaseObservation wraps OTel child span
            ├─> OtelAttributes.create_observation_attributes() sets Langfuse attributes
            └─> gen.usage_details = {...} → Sets token attributes via OTel span.set_attribute()
       ├─> OTel BatchSpanProcessor collects spans
       ├─> SpanProcessor propagates trace-level attributes to new spans
       ├─> MaskingExporter transforms the Langfuse copy when configured
       └─> OTLP Exporter sends spans to Langfuse
            ├─> POST /api/public/otel/v1/traces (OTLP format)
            ├─> x-langfuse-ingestion-version: 4
            ├─> Batch export (50 spans per batch, configurable)
            └─> Langfuse server converts OTLP → Langfuse ingestion format
```

### Score Creation

```
User Code
User Code
  ├─> Langfuse.create_score(...)
  │    ├─> Validate, normalize, and snapshot the score payload
  │    ├─> Add to bounded PendingScoreQueue
  │    └─> Flush by count, payload size, timer, or lifecycle boundary
  │         └─> ApiClient.send_batch() → POST /api/public/ingestion
  └─> Langfuse.create_score!(...)
       ├─> Validate, normalize, and snapshot the same score payload
       └─> ApiClient.create_score() → POST /api/public/scores
```

### Process Lifecycle

```
Application boot
  └─> Langfuse.configure stores settings
       └─> First trace or client call starts required resources lazily
            ├─> fork child rebuilds SDK-owned queues and workers
            ├─> explicit force_flush sends pending spans without shutdown
            └─> normal process exit shuts down tracing and scores once
```

## Technology Choices

### HTTP Client: Faraday

**Why Faraday?**
- Industry standard for Ruby HTTP
- Middleware architecture (retry, logging, etc.)
- Well-tested and maintained
- Flexible adapter support

### Templating: Mustache

**Why Mustache?**
- Logic-less (secure)
- Matches Langfuse JavaScript SDK
- Supports complex data structures
- Mature and stable

### Caching: Monitor + Rails.cache

**Why Monitor?**
- Built into Ruby standard library
- Simple, thread-safe synchronization
- No external dependencies

**Why Rails.cache?**
- Standard Rails pattern
- Works with Redis, Memcached, etc.
- Distributed caching built-in

### Tracing: OpenTelemetry

**Why OpenTelemetry?**
- CNCF standard for distributed tracing
- Supports W3C Trace Context when the host app configures a propagator
- Works with existing APM tools
- Future-proof (industry direction)
- OTLP export protocol (standardized)

**Components:**
- **OTLP Exporter** - Sends spans to Langfuse via `/api/public/otel/v1/traces`
- **BatchSpanProcessor** - Batches spans for efficient export
- **SpanProcessor** - Custom processor for attribute propagation
- **Application-configured W3C TraceContext Propagator** - Optional cross-service propagation outside the SDK

## Performance Considerations

### Cache Hit Rate

- **In-memory**: ~1ms
- **Rails.cache (Redis)**: ~1-2ms
- **API call**: ~100ms

**Target:** >99% cache hit rate in production

### Memory Usage

- **In-memory cache**: ~10KB per prompt × max_size × num_processes
- **Rails.cache**: Single copy in Redis (shared)

### Concurrency

- **In-memory**: Monitor-based locking (minimal contention)
- **Rails.cache**: Redis atomic operations (high concurrency)

## See Also

- [Caching Guide](CACHING.md) - Cache backends, SWR, and stampede protection
- [Tracing Guide](TRACING.md) - LLM observability and nested spans
- [Rails Integration](RAILS.md) - Rails-specific patterns and testing
- [API Reference](API_REFERENCE.md) - Complete method reference
