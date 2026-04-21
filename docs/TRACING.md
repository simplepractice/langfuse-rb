# LLM Tracing Guide

Complete guide to tracing LLM applications with the Langfuse Ruby SDK.

For basic setup and quick start examples, see [GETTING_STARTED.md](GETTING_STARTED.md).

## Table of Contents

- [Core Concepts](#core-concepts)
- [Quick Examples](#quick-examples)
- [Complete Examples](#complete-examples)
- [Best Practices](#best-practices)
- [Custom Trace IDs](#custom-trace-ids)
- [Advanced Usage](#advanced-usage)
- [Masking](#masking)

## Core Concepts

### Understanding Observations: Spans, Generations, and Events

| Concept | What It Is | When to Use | Has Duration? |
|---------|-----------|-------------|---------------|
| **Span** | A single unit of work | Any work that has a duration (retrieval, parsing, etc.) | ✅ Yes |
| **Generation** | A specialized span for LLM calls (Langfuse extension) | Calling an LLM (OpenAI, Anthropic, etc.) | ✅ Yes |
| **Event** | A point-in-time occurrence | Something happened at a point in time (log, feedback, flag) | ❌ No |

**Note:** In Langfuse Ruby SDK, traces are automatically created from the root observation. You don't explicitly create traces - they emerge from your observation hierarchy.

### Span

A **single unit of work** within a trace. Think of it as a function call or operation.

**Examples:**
- "Retrieve documents from vector DB"
- "Parse PDF file"
- "Call external API"
- "Database query"

**Properties:**
- Start/end timestamps (duration calculated automatically)
- Parent/child relationships (spans can be nested)
- Input/output data
- Metadata

```ruby
Langfuse.observe("vector-search", input: { query: "What is Ruby?" }) do |span|
  results = vector_db.search(query, limit: 5)
  span.update(output: { count: results.size, ids: results.map(&:id) })
  span.metadata = { db_latency_ms: 42 }
  results
end
```

### Generation

A **specialized span for LLM calls**. This is NOT a standard OpenTelemetry concept - it's a Langfuse convention.

**Why separate from regular spans?**
- LLM calls have unique properties: model name, tokens, cost
- Need special handling for prompt tracking
- Want to aggregate LLM metrics separately

**Properties (in addition to span properties):**
- Model name and version
- Token usage (prompt, completion, total)
- Model parameters (temperature, max_tokens, etc.)
- Prompt information (if using Langfuse prompts)

```ruby
Langfuse.observe("gpt4-call", as_type: :generation) do |gen|
  gen.model = "gpt-4"
  gen.input = [{ role: "user", content: "Hello" }]
  gen.model_parameters = { temperature: 0.7, max_tokens: 500 }
  
  response = openai_client.chat(...)
  
  gen.output = response.choices.first.message.content
  gen.usage_details = {
    prompt_tokens: 10,
    completion_tokens: 20,
    total_tokens: 30
  }
end
```

**Under the hood:** A generation is still a span in OpenTelemetry, but with additional LLM-specific attributes that Langfuse understands.

### Event

A **point-in-time occurrence** within a span or trace. Like a log message but structured.

**Examples:**
- "Cache hit"
- "User provided feedback"
- "Rate limit encountered"
- "Retry attempt"

**Properties:**
- Timestamp (automatically captured)
- Name
- Input/output data
- Metadata

```ruby
# Event using start_observation (auto-ends immediately)
Langfuse.observe("user-feedback", as_type: :event) do |event|
  event.update(input: { rating: "thumbs_up", comment: "Very helpful!" })
end

# Event using the event method on an observation
Langfuse.observe("operation") do |span|
  span.event(name: "cache-hit", input: { key: "prompt-greeting-v2" })
end
```

**Key difference from spans:**
- Events have NO duration (just a timestamp)
- Events don't have children
- Think "something happened" vs. "doing work"

### Trace-Level Attributes

Trace-level attributes (user_id, session_id, metadata, tags) are set using `Langfuse.propagate_attributes()`. This ensures all observations within the context inherit these attributes. Individual tags must be strings of ≤200 characters; oversized tags are dropped with a warning.

```ruby
Langfuse.propagate_attributes(
  user_id: "user-123",
  session_id: "session-456",
  metadata: { environment: "production" },
  tags: ["api", "v2"]
) do
  Langfuse.observe("operation") do |span|
    # This span and all children inherit user_id, session_id, etc.
  end
end
```

## Quick Examples

### Basic Observation with Generation

```ruby
Langfuse.propagate_attributes(user_id: "user-123") do
  Langfuse.observe("chat-completion", as_type: :generation) do |gen|
    gen.model = "gpt-4"
    gen.input = [{ role: "user", content: "Hello, how are you?" }]
    
    response = openai_client.chat(
      parameters: {
        model: "gpt-4",
        messages: [{ role: "user", content: "Hello, how are you?" }]
      }
    )

    gen.output = response.choices.first.message.content
    gen.usage_details = {
      prompt_tokens: response.usage.prompt_tokens,
      completion_tokens: response.usage.completion_tokens,
      total_tokens: response.usage.total_tokens
    }
  end
end
```

### Nested Observations

```ruby
Langfuse.observe("document-processing") do |parent|
  # Child span
  parent.start_observation("parse-pages") do |child|
    pages = extract_pages(pdf_file)
    child.update(output: { page_count: pages.size })
  end

  # Another child span
  parent.start_observation("extract-text") do |child|
    text = extract_text(pages)
    child.update(output: { text_length: text.length })
  end
end
```

## Complete Examples

### RAG Pipeline with Full Instrumentation

```ruby
def answer_question(user_id:, question:)
  Langfuse.propagate_attributes(
    user_id: user_id,
    metadata: { question: question, source: "web" }
  ) do
    # Step 1: Retrieve relevant documents
    documents = Langfuse.observe("document-retrieval", input: { query: question }) do |span|
      # Generate embedding for question
      embedding = span.start_observation("embed-question", as_type: :generation) do |gen|
        gen.model = "text-embedding-ada-002"
        gen.input = question
        
        result = openai_client.embeddings(
          parameters: { model: "text-embedding-ada-002", input: question }
        )
        gen.output = result.data.first.embedding
        gen.usage_details = { total_tokens: result.usage.total_tokens }
        result.data.first.embedding
      end

      # Search vector database
      docs = vector_db.similarity_search(embedding, limit: 3)
      span.update(
        output: { doc_ids: docs.map(&:id), count: docs.size },
        metadata: { search_latency_ms: 45 }
      )
      docs
    end

    # Step 2: Generate answer with LLM
    prompt = Langfuse.client.get_prompt("qa-with-context", label: "production")

    answer = Langfuse.observe("generate-answer", as_type: :generation) do |gen|
      gen.model = "gpt-4"
      gen.model_parameters = { temperature: 0.3, max_tokens: 500 }
      
      messages = prompt.compile(
        question: question,
        context: documents.map(&:content).join("\n\n")
      )
      gen.input = messages

      response = openai_client.chat(
        parameters: {
          model: "gpt-4",
          messages: messages,
          temperature: 0.3,
          max_tokens: 500
        }
      )

      gen.output = response.choices.first.message.content
      gen.usage_details = {
        prompt_tokens: response.usage.prompt_tokens,
        completion_tokens: response.usage.completion_tokens,
        total_tokens: response.usage.total_tokens
      }

      response.choices.first.message.content
    end

    # Step 3: Log result event
    Langfuse.observe("answer-generated", as_type: :event) do |event|
      event.update(
        input: { question: question },
        output: { answer: answer, sources: documents.map(&:id) }
      )
    end

    answer
  end
end
```

**Visual representation:**
```
Trace: (auto-created from root observation)
│
├─ Span: document-retrieval (0.8s)
│  ├─ Generation: embed-question (0.3s)
│  └─ (vector search happens here)
│
├─ Generation: generate-answer (2.0s)
│
└─ Event: answer-generated (instant)
```

### Multi-Turn Conversation

```ruby
def chat_conversation(user_id:, session_id:, messages:)
  Langfuse.propagate_attributes(
    user_id: user_id,
    session_id: session_id
  ) do
    # Load conversation history
    history = Langfuse.observe("load-history") do |span|
      history = conversation_store.get(session_id)
      span.update(output: { message_count: history.size })
      history
    end

    # Get system prompt
    prompt = Langfuse.client.get_prompt("chat-system", label: "production")
    system_message = prompt.compile(user_name: get_user_name(user_id))

    # Generate response
    response = Langfuse.observe("chat-completion", as_type: :generation) do |gen|
      gen.model = "gpt-4"
      gen.input = [system_message] + history + messages
      
      result = openai_client.chat(
        parameters: {
          model: "gpt-4",
          messages: [system_message] + history + messages
        }
      )

      gen.output = result.choices.first.message.content
      gen.usage_details = {
        prompt_tokens: result.usage.prompt_tokens,
        completion_tokens: result.usage.completion_tokens
      }

      result.choices.first.message.content
    end

    # Save to history
    Langfuse.observe("save-history") do |span|
      conversation_store.append(session_id, messages + [{ role: "assistant", content: response }])
      span.update(output: { saved: true })
    end

    response
  end
end
```

### Error Handling and Retry Tracking

```ruby
def call_llm_with_retry(prompt:, max_retries: 3)
  Langfuse.observe("llm-with-retry") do |root|
    attempt = 0

    root.start_observation("openai-call", as_type: :generation) do |gen|
      gen.model = "gpt-4"
      gen.input = prompt
      
      begin
        attempt += 1
        root.event(name: "attempt", input: { attempt_number: attempt })

        response = openai_client.chat(
          parameters: { model: "gpt-4", messages: prompt }
        )

        gen.output = response.choices.first.message.content
        gen.usage_details = {
          prompt_tokens: response.usage.prompt_tokens,
          completion_tokens: response.usage.completion_tokens
        }

        response.choices.first.message.content
      rescue OpenAI::RateLimitError => e
        root.event(name: "rate-limit", input: { attempt: attempt, error: e.message })

        if attempt < max_retries
          sleep(2 ** attempt)  # Exponential backoff
          retry
        else
          gen.level = "ERROR"
          gen.update(metadata: { error: "max_retries_exceeded", attempts: attempt })
          raise
        end
      rescue => e
        gen.level = "ERROR"
        gen.update(metadata: { error_class: e.class.name, error_message: e.message })
        raise
      end
    end
  end
end
```

## Best Practices

### 1. Always Capture Usage Information

```ruby
# ✅ Good - captures token usage
Langfuse.observe("gpt4", as_type: :generation) do |gen|
  gen.model = "gpt-4"
  gen.input = messages
  
  response = openai_client.chat(...)
  gen.output = response.choices.first.message.content
  gen.usage_details = {
    prompt_tokens: response.usage.prompt_tokens,
    completion_tokens: response.usage.completion_tokens,
    total_tokens: response.usage.total_tokens
  }
end

# ❌ Bad - missing usage information
Langfuse.observe("gpt4", as_type: :generation) do |gen|
  gen.model = "gpt-4"
  gen.input = messages
  
  response = openai_client.chat(...)
  gen.output = response.choices.first.message.content
  # Missing: gen.usage_details = ...
end
```

### 2. Use Descriptive Names

```ruby
# ✅ Good - clear what this does
Langfuse.observe("retrieve-user-documents")

# ❌ Bad - too generic
Langfuse.observe("process")
```

### 3. Add Metadata for Context

```ruby
# ✅ Good - includes useful context
Langfuse.observe("database-query") do |span|
  results = db.query(sql)
  span.update(
    output: { count: results.size },
    metadata: {
      query_time_ms: elapsed_time,
      rows_scanned: results.meta.rows_scanned,
      cache_hit: false
    }
  )
end
```

### 4. Link Prompts to Generations

```ruby
# ✅ Good - automatic prompt tracking
prompt = Langfuse.client.get_prompt("greeting", version: 2)
Langfuse.observe("greet", as_type: :generation) do |gen|
  gen.model = "gpt-4"
  gen.update(prompt: { name: prompt.name, version: prompt.version })
  # Langfuse will automatically link this generation to the prompt
end

# ❌ Less useful - no prompt tracking
Langfuse.observe("greet", as_type: :generation) do |gen|
  gen.model = "gpt-4"
  # Which prompt was used? What version?
end
```

### 5. Use Events for Important Milestones

```ruby
Langfuse.propagate_attributes(user_id: "user-123") do
  Langfuse.observe("user-onboarding") do |span|
    span.event(name: "started", input: { source: "mobile_app" })

    # ... do work ...

    span.event(name: "completed", input: { duration_minutes: 5 })
    span.event(name: "user-feedback", input: { rating: 5 })
  end
end
```

### 6. Set Error Levels Appropriately

```ruby
Langfuse.observe("api-call") do |span|
  begin
    result = external_api.call
    span.update(output: result)
  rescue RateLimitError => e
    span.level = "WARNING"  # Recoverable error
    span.update(metadata: { error: e.message, retry_after: 60 })
  rescue => e
    span.level = "ERROR"  # Unexpected error
    span.update(metadata: { error_class: e.class.name, error: e.message })
    raise
  end
end
```

### 7. Use propagate_attributes Early

```ruby
# ✅ Good - attributes propagate to all observations
Langfuse.propagate_attributes(user_id: "user-123", session_id: "session-456") do
  Langfuse.observe("operation") do |span|
    span.start_observation("child") do |child|
      # Child inherits user_id and session_id
    end
  end
end

# ❌ Less ideal - attributes only on specific observations
Langfuse.observe("operation") do |span|
  span.update_trace(user_id: "user-123", session_id: "session-456")
  # Only this span has the attributes, not children created before this call
end
```

## Custom Trace IDs

By default, Langfuse generates random trace IDs. Custom trace IDs let you control the trace identity — useful when you need to reference a trace later from a different part of your system.

### When to Use Custom Trace IDs

- **Background job scoring** — a web request creates a trace, a worker scores it hours later
- **Cross-service correlation** — multiple services contribute to the same logical trace
- **Idempotent retries** — reprocessing the same input lands on the same trace
- **External ID correlation** — link Langfuse traces to your database rows without storing trace IDs

### Deterministic Trace IDs from Seeds

Generate the same trace ID from the same seed, every time, across Ruby, Python, and JS SDKs:

```ruby
trace_id = Langfuse.create_trace_id(seed: "order-42")
# => "3bf8b157c4238eefe5ae4a66eca81c6b"

# Same seed, same ID — even from a different process
trace_id_again = Langfuse.create_trace_id(seed: "order-42")
# => "3bf8b157c4238eefe5ae4a66eca81c6b"
```

Under the hood: `SHA-256(seed)[0..15]` → 32-char lowercase hex. This matches the Python SDK's `Langfuse.create_trace_id(seed=...)` and the JS SDK's `createTraceId(seed)`.

> [!IMPORTANT]
> Seeds must be **String** values. Passing non-String types (integers, symbols) raises `ArgumentError`. This ensures cross-SDK parity — Python and JS also reject non-strings.

> [!WARNING]
> Do not pass PII, secrets, or credentials as seeds. The seed itself appears in your application code and may leak through logs and backtraces. Use stable, non-sensitive identifiers: database primary keys, UUIDs, or request IDs.

### Using Custom Trace IDs

Pass `trace_id:` to `observe` or `start_observation`:

```ruby
trace_id = Langfuse.create_trace_id(seed: "order-42")

# Block-based
Langfuse.observe("process-order", trace_id: trace_id) do |span|
  span.update_trace(user_id: "user-123", tags: ["orders"])
  result = process_order(42)
  span.update(output: result)
end

# Stateful
obs = Langfuse.observe("process-order", trace_id: trace_id)
obs.update(output: { status: "done" })
obs.end
```

You can also use a pre-generated hex trace ID directly (must be 32 lowercase hex characters):

```ruby
# ✅ Good — valid 32-char lowercase hex
Langfuse.observe("op", trace_id: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4") { ... }

# ❌ Bad — not valid hex format
Langfuse.observe("op", trace_id: "my-custom-id") { ... }
# => ArgumentError: Invalid trace_id
```

### Complete Example: Web Request + Background Scoring

```ruby
# === Web server ===
class OrdersController < ApplicationController
  def create
    order = Order.create!(params)

    # Deterministic trace ID from order's primary key
    trace_id = Langfuse.create_trace_id(seed: "order-#{order.id}")

    Langfuse.observe("process-order", trace_id: trace_id) do |span|
      span.update_trace(user_id: current_user.id, tags: ["orders"])

      span.start_observation("validate", input: order.attributes) do |child|
        child.update(output: { valid: true })
      end

      span.start_observation("llm-summarize", as_type: :generation) do |gen|
        gen.model = "gpt-4"
        gen.input = [{ role: "user", content: "Summarize: #{order.description}" }]
        summary = call_llm(gen.input)
        gen.update(output: summary, usage_details: { input: 50, output: 20 })
      end
    end

    # No need to store trace_id — it can be recomputed from order.id
    render json: order
  end
end

# === Background worker (hours later) ===
class OrderQualityJob
  def perform(order_id)
    # Recompute the same trace ID — no database lookup needed
    trace_id = Langfuse.create_trace_id(seed: "order-#{order_id}")

    score = evaluate_order_quality(order_id)

    Langfuse.create_score(
      name: "order_quality",
      value: score,
      trace_id: trace_id,
      data_type: :numeric,
      comment: "Async quality evaluation"
    )
  end
end
```

## Advanced Usage

### Custom Observability Levels

```ruby
Langfuse.observe("production-query") do |root|
  # Debug-level span (only in development/staging)
  root.start_observation("cache-check") do |span|
    span.level = "DEBUG"
    # ... cache logic
  end

  # Default-level generation (always tracked)
  root.start_observation("llm-call", as_type: :generation) do |gen|
    gen.model = "gpt-4"
    gen.level = "DEFAULT"
    # ... LLM call
  end

  # Warning-level event (important but not error)
  if cache_miss_rate > 0.8
    root.event(name: "high-cache-miss-rate", input: { rate: cache_miss_rate })
    root.level = "WARNING"
  end
end
```

### Background Jobs and Async Processing

```ruby
# In controller - create observation and pass trace context
Langfuse.propagate_attributes(user_id: current_user.id) do
  Langfuse.observe("document-upload") do |span|
    document = Document.create!(params)
    
    # Get trace context to pass to background job
    trace_id = span.trace_id
    
    ProcessDocumentJob.perform_later(document.id, trace_id)
    
    span.event(name: "job-enqueued", input: { document_id: document.id })
  end
end

# Background job - continue trace
class ProcessDocumentJob < ApplicationJob
  def perform(document_id, trace_id = nil)
    # Note: Cross-process trace continuation requires additional setup
    # For now, create a new observation with metadata linking to original trace
    Langfuse.propagate_attributes(metadata: { original_trace_id: trace_id }) do
      Langfuse.observe("process-document") do |span|
        span.start_observation("extract-text") do |child|
          text = extract_text(document_id)
          child.update(output: { text_length: text.length })
        end

        span.start_observation("summarize", as_type: :generation) do |gen|
          gen.model = "gpt-4"
          summary = generate_summary(text)
          gen.update(output: summary)
        end
      end
    end
  end
end
```

### Stateful API (Manual End)

```ruby
# Create observation without block
span = Langfuse.observe("long-running-operation", input: { query: "test" })

# Do work...
result = perform_operation

# Update and end manually
span.update(output: result, metadata: { duration_ms: 150 })
span.end
```

### Using update() Method

```ruby
# ✅ Good - using update() method
Langfuse.observe("operation") do |span|
  span.update(
    output: { result: "success" },
    metadata: { duration_ms: 150 },
    level: "DEFAULT"
  )
end

# ✅ Also good - using setters
Langfuse.observe("operation") do |span|
  span.output = { result: "success" }
  span.metadata = { duration_ms: 150 }
  span.level = "DEFAULT"
end
```

### Specialized Observation Types

The SDK supports several specialized observation types beyond spans and generations:

- **Agent** (`as_type: :agent`) - For agent-based workflows
- **Tool** (`as_type: :tool`) - For tool/function calls
- **Chain** (`as_type: :chain`) - For multi-step workflows
- **Retriever** (`as_type: :retriever`) - For document retrieval
- **Evaluator** (`as_type: :evaluator`) - For quality assessment
- **Guardrail** (`as_type: :guardrail`) - For safety checks
- **Embedding** (`as_type: :embedding`) - For embedding generation

```ruby
# Example: Agent workflow
Langfuse.observe("agent-workflow", as_type: :agent) do |agent|
  agent.update(input: { task: "Find weather for NYC" })
  
  agent.start_observation("tool-call", as_type: :tool) do |tool|
    weather = fetch_weather("NYC")
    tool.update(output: weather)
  end
  
  agent.update(output: { result: "Sunny, 72°F" })
end
```

## Masking

Mask sensitive data in `input`, `output`, and `metadata` fields before they are sent to Langfuse. Configure a mask callable on `Langfuse.configuration.mask` — it applies to all traces, observations, events, and propagated metadata.

### Setup

```ruby
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  config.mask = lambda { |data:|
    if data.is_a?(Hash)
      data.transform_values { |v| v.is_a?(String) ? "[REDACTED]" : v }
    else
      "[REDACTED]"
    end
  }
end
```

### Contract

The mask callable must:

- Accept a `data:` keyword argument (the raw field value — Hash, String, Array, etc.)
- Return the masked version (must be JSON-serializable)

```ruby
# Lambda
config.mask = ->(data:) { data.is_a?(Hash) ? data.except(:api_key, :token) : data }

# Method object
config.mask = method(:my_masking_function)

# Any object responding to #call
config.mask = MyMaskingService.new
```

### What Gets Masked

Masking applies to three fields at every callsite:

| Field      | Trace | Observation | Event | Propagated |
|------------|-------|-------------|-------|------------|
| `input`    | ✅    | ✅          | ✅    | —          |
| `output`   | ✅    | ✅          | —     | —          |
| `metadata` | ✅    | ✅          | —     | ✅         |

Fields like `model`, `name`, `tags`, `environment`, and `usage_details` are **not** masked.

### Fail-Closed Behavior

If the mask callable raises an exception, the entire field is replaced with:

```
<fully masked due to failed mask function>
```

A warning is logged. No sensitive data leaks — the SDK is fail-closed by design.

### Example: PII Redaction

```ruby
PII_KEYS = %w[email phone ssn api_key token password secret].freeze

config.mask = lambda { |data:|
  case data
  when Hash
    data.each_with_object({}) do |(k, v), masked|
      masked[k] = PII_KEYS.any? { |pii| k.to_s.downcase.include?(pii) } ? "[PII]" : v
    end
  when String
    data.gsub(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z]{2,}\b/i, "[EMAIL]")
  else
    data
  end
}
```

## OpenTelemetry Integration

The SDK is built on OpenTelemetry, which provides:

### Automatic Context Propagation

Trace context automatically flows through:
- HTTP requests (via headers)
- Background jobs (if properly configured)
- Database queries (with OTel instrumentation)
- Redis operations (with OTel instrumentation)

### APM Integration

Traces can be exported to multiple observability platforms:

```ruby
# config/initializers/opentelemetry.rb
require 'opentelemetry/sdk'
require 'langfuse-rb/otel_setup'

Langfuse::OtelSetup.configure do |config|
  config.service_name = 'my-rails-app'
  config.service_version = ENV['APP_VERSION']
end
```

Your traces will appear in:
- Langfuse (for LLM-specific analytics)
- Any OpenTelemetry-compatible platform

### W3C Trace Context

Langfuse spans are compatible with the [W3C Trace Context](https://www.w3.org/TR/trace-context/) standard for distributed tracing, but the SDK does not install a global propagator for you. If you want cross-service propagation, configure `OpenTelemetry.propagation` in your application:

```ruby
require "opentelemetry/trace/propagation/trace_context"

OpenTelemetry.propagation =
  OpenTelemetry::Trace::Propagation::TraceContext::TextMapPropagator.new
```

That global OpenTelemetry propagator is separate from `Langfuse::Propagation`, which handles Langfuse-specific trace attributes and optional baggage propagation.

With an application-configured propagator, traces can flow across services using headers like:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
```

This allows traces to flow seamlessly across:
- Ruby services
- Node.js services
- Python services
- Go services
- Any service that implements W3C Trace Context

## See Also

- [Scoring Guide](SCORING.md) - Add quality scores to traces
- [Prompts Guide](PROMPTS.md) - Managed prompts with tracing integration
- [Rails Integration](RAILS.md) - Controller-level tracing patterns
- [API Reference](API_REFERENCE.md) - Complete method reference
- [Langfuse Documentation](https://langfuse.com/docs)
- [OpenTelemetry Ruby Documentation](https://opentelemetry.io/docs/instrumentation/ruby/)
- [W3C Trace Context Specification](https://www.w3.org/TR/trace-context/)
