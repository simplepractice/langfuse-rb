# Scoring API Guide

Add quality scores to your traces and observations for evaluation and analytics.

## Overview

Use scores to evaluate LLM output:

- **Human feedback:** User thumbs up/down, star ratings
- **Automated metrics:** Accuracy, relevance, safety checks
- **A/B testing:** Compare prompt/model performance

Scores can be attached to:

- Entire traces (end-to-end quality)
- Individual observations (LLM call quality)

## Choose a Delivery Mode

The SDK provides two score creation contracts:

| Method | Delivery | Return value | Best for |
| --- | --- | --- | --- |
| `create_score` | Asynchronous ingestion queue | `nil` | Inline telemetry and high-volume evaluation |
| `create_score!` | Synchronous Scores API request | Created score ID | User feedback, durable verdicts, and workflows that must observe API failure |

`create_score` confirms that the SDK accepted the score into its bounded queue.
It does not confirm backend storage.
`create_score!` confirms that Langfuse accepted the HTTP request.
For retryable synchronous work, use a stable `id`.
After an uncertain network failure, use the same complete payload for the retry.

Both methods use the same score validation and environment order.
An explicit score `environment` has first priority.
`config.environment` has second priority.
Otherwise, Langfuse uses its `default` environment.

When `tracing_enabled` is false, both methods are no-ops.
In this mode, `create_score!` returns `nil`.
`OTEL_SDK_DISABLED=true` does not disable scores.

## Score Data Types

### Numeric

Continuous or discrete numbers (integers, floats):

```ruby
client.create_score(
  name: "accuracy",
  value: 0.85,
  trace_id: "abc123...",
  data_type: :numeric
)
```

**Common use cases:**
- Accuracy scores (0.0-1.0)
- Similarity scores (0.0-1.0)
- BLEU/ROUGE scores
- Confidence levels

### Boolean

True/false values (normalized to 0 or 1):

```ruby
client.create_score(
  name: "is_safe",
  value: true,  # or false, 0, 1
  trace_id: "abc123...",
  data_type: :boolean
)
```

**Common use cases:**
- Safety checks (safe/unsafe)
- Correctness (correct/incorrect)
- Policy compliance (compliant/non-compliant)

### Categorical

String labels:

```ruby
client.create_score(
  name: "sentiment",
  value: "positive",  # or "negative", "neutral"
  trace_id: "abc123...",
  data_type: :categorical
)
```

**Common use cases:**
- Sentiment analysis
- Content categories
- Quality tiers (low/medium/high)

### Text

Free-form string notes (1 to 500 characters):

```ruby
client.create_score(
  name: "reviewer_notes",
  value: "The response was helpful but could be more concise.",
  trace_id: "abc123...",
  data_type: :text
)
```

**Common use cases:**
- Reviewer notes and qualitative feedback
- Short explanations attached to a trace or observation

Values must be strings containing 1 to 500 characters; anything else raises
`ArgumentError`.

### Correction (Corrected Outputs)

Corrections capture an improved version of an LLM output directly on a trace or
observation. They are scores with `dataType: "CORRECTION"`; Langfuse persists
their name as `"output"`:

```ruby
client.create_score(
  name: "output",                        # persisted by Langfuse as "output"
  value: "The corrected output text",    # the full replacement output
  trace_id: "abc123...",
  observation_id: "def456...",           # optional: target an observation
  data_type: :correction
)
```

**Common use cases:**
- Domain experts documenting what the model should have generated
- Human-in-the-loop review workflows
- Building fine-tuning datasets from corrected outputs

Values must be strings; there is no length limit. Provide structured
corrections as JSON text when appropriate — the SDK does not serialize objects
for you. A correction must have a `trace_id`; `observation_id` may additionally
target one observation. Session, dataset-run, and score-config associations are
rejected because Langfuse only accepts corrections on traces or observations.
Corrections appear in the Langfuse UI alongside the original output with a diff
view, and can be read back through the v3 scores API
(`GET /api/public/v3/scores?dataType=CORRECTION`).

### Text/Correction vs. Experiment Evaluations

Text and correction scores are general scores, not experiment metrics.
`Langfuse::Evaluation` (used by experiment evaluators — see
[EXPERIMENTS.md](EXPERIMENTS.md)) intentionally accepts only `:numeric`,
`:boolean`, and `:categorical` and raises `ArgumentError` for `:text` and
`:correction`, matching the Python SDK. Create corrections and text notes
through `create_score` against the trace or observation instead.

## Creating Scores

### Client-Level API

**Score a trace:**

```ruby
client = Langfuse.client

client.create_score(
  name: "user_satisfaction",
  value: 5,
  trace_id: "abc123...",
  data_type: :numeric,
  comment: "User gave 5-star rating",
  metadata: { user_id: "user_456" }
)
```

**Score an observation:**

```ruby
client.create_score(
  name: "llm_quality",
  value: 0.92,
  observation_id: "obs_789...",
  data_type: :numeric
)
```

**Score both trace and observation:**

```ruby
client.create_score(
  name: "overall_quality",
  value: 4,
  trace_id: "abc123...",
  observation_id: "obs_789...",  # Optional: specific observation within trace
  data_type: :numeric
)
```

### Module-Level API

Convenience methods delegating to the client:

```ruby
Langfuse.create_score(
  name: "quality",
  value: 0.85,
  trace_id: "abc123...",
  data_type: :numeric
)
```

Use the synchronous module-level method when delivery is part of the caller's contract:

```ruby
score_id = Langfuse.create_score!(
  id: "feedback-#{feedback.id}",
  name: "user_feedback",
  value: true,
  trace_id: trace_id,
  data_type: :boolean
)
```

### Scoring Active Observations

Score the currently active observation (from OpenTelemetry context):

```ruby
Langfuse.observe("generate-summary", as_type: :generation) do |gen|
  summary = generate_summary(document)

  # Score this specific generation
  Langfuse.score_active_observation(
    name: "summary_quality",
    value: 0.88,
    data_type: :numeric
  )

  summary
end
```

Use this method when the traced block does not have an observation ID.

### Scoring Active Traces

Score the entire current trace:

```ruby
Langfuse.observe("user-request") do |span|
  result = process_request(params)

  # Score the entire trace
  Langfuse.score_active_trace(
    name: "user_satisfaction",
    value: 5,
    data_type: :numeric
  )

  result
end
```

## Complete Examples

### User Feedback (Thumbs Up/Down)

```ruby
# Rails controller
class FeedbacksController < ApplicationController
  def create
    trace_id = params[:trace_id]
    feedback = params[:feedback]  # "positive" or "negative"

    Langfuse.create_score(
      name: "user_feedback",
      value: feedback == "positive" ? 1 : 0,
      trace_id: trace_id,
      data_type: :boolean,
      comment: "User clicked #{feedback}",
      metadata: { user_id: current_user.id }
    )

    render json: { success: true }
  end
end
```

### Automated Quality Check

```ruby
def generate_with_quality_check(prompt)
  response = nil

  Langfuse.observe("llm-generation", as_type: :generation) do |gen|
    response = openai_client.chat(
      parameters: {
        model: "gpt-4",
        messages: [{ role: "user", content: prompt }]
      }
    )

    output = response.dig("choices", 0, "message", "content")

    gen.model = "gpt-4"
    gen.input = prompt
    gen.output = output
    gen.usage_details = {
      prompt_tokens: response.dig("usage", "prompt_tokens"),
      completion_tokens: response.dig("usage", "completion_tokens"),
      total_tokens: response.dig("usage", "total_tokens")
    }

    # Automated quality check
    quality_score = check_quality(output)  # Your custom logic

    Langfuse.score_active_observation(
      name: "automated_quality",
      value: quality_score,
      data_type: :numeric,
      comment: "Automated quality check"
    )

    response
  end

  response
end

def check_quality(text)
  # Example: simple length-based heuristic
  # Replace with actual quality model
  text.length > 50 ? 0.9 : 0.5
end
```

### Multi-Dimensional Scoring

Score multiple aspects of a single generation:

```ruby
Langfuse.observe("customer-support-response", as_type: :generation) do |gen|
  response = generate_support_response(ticket)

  gen.update(output: response)

  # Score multiple dimensions
  Langfuse.score_active_observation(name: "helpfulness", value: 0.92, data_type: :numeric)
  Langfuse.score_active_observation(name: "politeness", value: 0.88, data_type: :numeric)
  Langfuse.score_active_observation(name: "is_safe", value: true, data_type: :boolean)
  Langfuse.score_active_observation(name: "tone", value: "professional", data_type: :categorical)

  response
end
```

### Retrieval Quality (RAG)

Score retriever performance:

```ruby
Langfuse.observe("rag-pipeline") do |trace|
  # Retrieval
  docs = Langfuse.observe("retrieve-docs", as_type: :retriever) do |retriever|
    results = vector_store.search(query, top_k: 5)

    retriever.update(
      input: query,
      output: results.map(&:to_h)
    )

    # Score retrieval quality
    relevance = calculate_relevance(results, query)
    Langfuse.score_active_observation(
      name: "retrieval_relevance",
      value: relevance,
      data_type: :numeric
    )

    results
  end

  # Generation
  answer = Langfuse.observe("generate-answer", as_type: :generation) do |gen|
    response = llm.generate(query: query, context: docs)

    gen.update(output: response)

    # Score generation quality
    Langfuse.score_active_observation(
      name: "answer_quality",
      value: 0.85,
      data_type: :numeric
    )

    response
  end

  # Score overall pipeline
  Langfuse.score_active_trace(
    name: "pipeline_quality",
    value: 0.90,
    data_type: :numeric
  )

  answer
end
```

## Batching Behavior

Scores are batched for efficiency:

**Default settings:**
- `batch_size`: 50 scores per batch
- `flush_interval`: 10 seconds
- `score_queue_capacity`: 100,000 pending asynchronous scores

```ruby
# These scores are queued, not sent immediately
20.times do |i|
  Langfuse.create_score(
    name: "quality",
    value: rand,
    trace_id: "trace_#{i}",
    data_type: :numeric
  )
end

# Scores sent in batch after flush_interval or when batch_size reached
```

**Configure batching:**

```ruby
Langfuse.configure do |config|
  config.batch_size = 100      # Larger batches
  config.flush_interval = 5    # More frequent flushes
  config.score_queue_capacity = 20_000
end
```

The asynchronous queue has a fixed capacity.
If the queue is full, the SDK logs an error and drops the new score.
The call does not wait for capacity.
The SDK keeps each multi-score JSON payload below 2.5 MB.
Retryable failures keep the batch at the front of the queue.
The SDK logs and discards permanent batch failures.
Thus, the SDK can send later valid scores.
Use `create_score!` when the caller needs synchronous delivery and an API error result.

**Manual flush:**

Force immediate send:

```ruby
Langfuse.create_score(name: "critical", value: 1, trace_id: "abc", data_type: :numeric)
Langfuse.flush_scores  # Send immediately
```

Use a manual flush before an immediate readback.
Also use it at an explicit durability boundary:

```ruby
Langfuse.flush_scores
```

A normal process exit flushes pending scores automatically.
Do not flush on every request.
An abrupt termination such as `SIGKILL` cannot run the exit hook.

## Reading Scores

Use `client.list_scores` for typed score records and cursor pagination:

```ruby
page = Langfuse.client.list_scores(
  trace_id: trace_id,
  data_type: "BOOLEAN,CORRECTION",
  fields: "details,subject"
)

page.fetch("data").each do |score|
  puts "#{score['dataType']}: #{score['value'].inspect}"
end
```

See [DATA_ACCESS.md](DATA_ACCESS.md) for the v3 response contract, independent CLI readback, and end-to-end verification.

## Sampling Behavior

Trace-linked scores follow the same deterministic `sample_rate` decision as traces.

- If a trace is sampled out, scores with that lowercase 32-hex `trace_id` are dropped.
- Scores without `trace_id` (for example, session-only or dataset-run-only) are not sampled out.
- Legacy/non-valid trace IDs are treated as in-sample for backwards compatibility. This matches `langfuse-python`: only lowercase 32-character hex trace IDs participate in sampling, while uppercase or custom IDs are treated as legacy.
- Sampling is decided by the Langfuse client's `sample_rate` alone. An active span's OpenTelemetry trace flags do not override the decision. If you run Langfuse inside a host OTel tracer with its own sampler, that tracer's flags will not steer Langfuse score emission.
- Score sampling is scoped to the client that creates the score. Another Langfuse client or global OpenTelemetry provider in the same process does not change that client's score sampling.
- The client snapshots `sample_rate` when it is built. If you mutate `config.sample_rate` afterward, call `Langfuse.reset!` and rebuild the client before expecting different trace or score sampling.

```ruby
Langfuse.configure do |config|
  config.sample_rate = 0.1
end
```

## Getting Trace/Observation IDs

### From Observation Object

```ruby
Langfuse.observe("my-operation") do |obs|
  trace_id = obs.trace_id
  observation_id = obs.id

  # Later: score this specific operation
  Langfuse.create_score(
    name: "quality",
    value: 0.9,
    trace_id: trace_id,
    observation_id: observation_id,
    data_type: :numeric
  )
end
```

### From Trace URL

```ruby
Langfuse.observe("operation") do |obs|
  url = obs.trace_url
  # => "https://cloud.langfuse.com/traces/abc123..."

  # Extract trace_id from URL
  trace_id = url.split('/').last
end
```

### Store for Later Scoring

#### Recommended: Deterministic Trace IDs

Use `Langfuse.create_trace_id(seed:)` to derive the trace ID from a stable external identifier. No database column needed — any code that knows the external ID can recompute the trace ID:

```ruby
# During request — derive trace_id from order ID
trace_id = Langfuse.create_trace_id(seed: "order-#{order.id}")

Langfuse.observe("process-order", trace_id: trace_id) do |obs|
  result = process_request(order)
  obs.update(output: result)
end

# Later, in a background job or different service, calculate the ID again
trace_id = Langfuse.create_trace_id(seed: "order-#{order.id}")

Langfuse.create_score(
  name: "quality",
  value: evaluate(order),
  trace_id: trace_id,
  data_type: :numeric
)
```

#### Alternative: Store the Trace ID

If you do not have a stable external identifier, capture and store the trace ID:

```ruby
# During request
trace_id = nil

Langfuse.observe("user-request") do |obs|
  trace_id = obs.trace_id
  result = process_request
end

# Store trace_id with response
Response.create!(
  user_id: current_user.id,
  trace_id: trace_id,
  content: result
)

# Later: User provides feedback
response = Response.find(params[:id])

Langfuse.create_score(
  name: "user_rating",
  value: params[:rating],
  trace_id: response.trace_id,
  data_type: :numeric
)
```

## Score Metadata

Add context to scores:

```ruby
Langfuse.create_score(
  name: "expert_rating",
  value: 4,
  trace_id: "abc123",
  data_type: :numeric,
  comment: "Expert reviewer noted excellent factual accuracy",
  metadata: {
    reviewer_id: "expert_42",
    review_date: Time.now.iso8601,
    criteria: ["accuracy", "clarity", "completeness"],
    model_version: "gpt-4-2024-01"
  }
)
```

**Metadata use cases:**
- Reviewer information
- Evaluation criteria
- Model/prompt versions
- Timestamp details
- Custom tags

## See Also

- [TRACING.md](TRACING.md) - Creating observations to score
- [API_REFERENCE.md](API_REFERENCE.md) - Complete scoring API reference
- [CONFIGURATION.md](CONFIGURATION.md) - Batch configuration
- [DATA_ACCESS.md](DATA_ACCESS.md) - Read and verify persisted scores
