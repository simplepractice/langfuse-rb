# Scoring API Guide

Add quality scores to your traces and observations for evaluation and analytics.

## Overview

Scores let you evaluate LLM outputs:
- **Human feedback:** User thumbs up/down, star ratings
- **Automated metrics:** Accuracy, relevance, safety checks
- **A/B testing:** Compare prompt/model performance

Scores can be attached to:
- Entire traces (end-to-end quality)
- Individual observations (LLM call quality)

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

This is useful when you don't have the observation ID but want to score from within the traced block.

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
    gen.usage = {
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
end
```

**Manual flush:**

Force immediate send:

```ruby
Langfuse.create_score(name: "critical", value: 1, trace_id: "abc", data_type: :numeric)
Langfuse.flush_scores  # Send immediately
```

Use before shutdown:

```ruby
# Before process exit
Langfuse.flush_scores
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

Common pattern: Store trace ID with user interaction for async scoring:

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
