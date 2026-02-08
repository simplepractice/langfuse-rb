# Experiments

Systematic evaluation of tasks against datasets. Run your LLM pipeline over a set of inputs, score the outputs, and compare runs in the Langfuse UI.

## Quick Start

```ruby
client = Langfuse.client

result = client.run_experiment(
  name: "qa-v1",
  dataset_name: "qa-eval",
  task: ->(item) { my_llm_call(item.input) }
)

puts result.format
puts "#{result.successes.size} passed, #{result.failures.size} failed"
puts result.dataset_run_url  # => link to Langfuse UI
```

## Entry Points

### From Client (fetches dataset automatically)

```ruby
result = client.run_experiment(
  name: "qa-v1",
  dataset_name: "qa-eval",
  task: ->(item) { my_llm_call(item.input) },
  evaluators: [accuracy_evaluator],
  metadata: { model: "gpt-4o" }
)
```

### From DatasetClient (uses existing items)

```ruby
dataset = client.get_dataset("qa-eval")

result = dataset.run_experiment(
  name: "qa-v1",
  task: ->(item) { my_llm_call(item.input) },
  evaluators: [accuracy_evaluator]
)
```

### Local Data Mode

Run experiments without a server-side dataset:

```ruby
result = client.run_experiment(
  name: "qa-local",
  data: [
    { input: "What is Ruby?", expected_output: "A programming language" },
    { input: "What is Python?", expected_output: "A programming language" }
  ],
  task: ->(item) { my_llm_call(item.input) }
)
```

Each hash is wrapped into an `ExperimentItem` struct with `input`, `expected_output`, and `metadata` fields. Both symbol and string keys are accepted.

## Parameters

### `Client#run_experiment`

| Parameter       | Type             | Required | Description                                    |
| --------------- | ---------------- | -------- | ---------------------------------------------- |
| `name`          | String           | Yes      | Experiment name                                |
| `task`          | Proc             | Yes      | Callable receiving item, returning output      |
| `dataset_name`  | String           | No*      | Dataset to run against                         |
| `data`          | Array            | No*      | Local data items (hashes or DatasetItemClients) |
| `description`   | String           | No       | Run description                                |
| `evaluators`    | Array\<Proc\>    | No       | Item-level evaluators                          |
| `run_evaluators`| Array\<Proc\>    | No       | Run-level evaluators                           |
| `metadata`      | Hash             | No       | Metadata attached to each trace                |
| `run_name`      | String           | No       | Explicit run name (default: "name - timestamp")|

\* Provide exactly one of `dataset_name` or `data`.

### `DatasetClient#run_experiment`

Same parameters minus `dataset_name` and `data` (items come from the dataset).

## Writing Evaluators

### Item-Level Evaluators

An evaluator is any callable (Proc, lambda, method) that receives keyword arguments and returns an `Evaluation`, an Array of them, or a Hash:

```ruby
accuracy = ->(input:, output:, expected_output:, item:, **) {
  score = output.to_s.downcase.include?(expected_output.to_s.downcase) ? 1.0 : 0.0
  Langfuse::Evaluation.new(name: "accuracy", value: score)
}

result = client.run_experiment(
  name: "qa-v1",
  dataset_name: "qa-eval",
  task: ->(item) { my_llm_call(item.input) },
  evaluators: [accuracy]
)
```

**Evaluator keyword arguments:**

| Keyword           | Type                              | Description                 |
| ----------------- | --------------------------------- | --------------------------- |
| `input`           | Object                            | The item's input            |
| `output`          | Object                            | The task's return value     |
| `expected_output` | Object                            | The item's expected output  |
| `item`            | DatasetItemClient / ExperimentItem| The original item           |
| `metadata`        | Hash (optional)                   | Item metadata (only passed if evaluator accepts it) |

**Return types:**

- `Evaluation` — single score
- `Array<Evaluation>` — multiple scores
- `Hash` — converted to `Evaluation` (keys: `name`, `value`, `comment`, `data_type`)

### Evaluation Value Types

```ruby
# Numeric (default)
Langfuse::Evaluation.new(name: "relevance", value: 0.85)

# Boolean
Langfuse::Evaluation.new(name: "is_correct", value: true, data_type: :boolean)

# Categorical
Langfuse::Evaluation.new(name: "quality_tier", value: "high", data_type: :categorical)

# With comment and metadata
Langfuse::Evaluation.new(
  name: "relevance",
  value: 0.85,
  comment: "Mostly relevant, minor tangent",
  metadata: { model: "gpt-4o" }
)
```

### Run-Level Evaluators

Run-level evaluators receive all item results at once, for aggregate metrics:

```ruby
avg_length = ->(item_results:) {
  lengths = item_results.select(&:success?).map { |r| r.output.to_s.length }
  avg = lengths.sum.to_f / lengths.size
  Langfuse::Evaluation.new(name: "avg_output_length", value: avg)
}

result = client.run_experiment(
  name: "qa-v1",
  dataset_name: "qa-eval",
  task: ->(item) { my_llm_call(item.input) },
  run_evaluators: [avg_length]
)
```

Run-level evaluators receive `item_results:` — an `Array<ItemResult>`.

## Result Objects

### ExperimentResult

Returned by `run_experiment`.

| Property           | Type                | Description                                |
| ------------------ | ------------------- | ------------------------------------------ |
| `name`             | String              | Experiment name                            |
| `run_name`         | String, nil         | Auto-generated run name (name + timestamp) |
| `description`      | String, nil         | Run description                            |
| `item_results`     | Array\<ItemResult\> | All per-item results                       |
| `run_evaluations`  | Array\<Evaluation\> | Run-level evaluation results               |
| `dataset_run_id`   | String, nil         | Dataset run ID from the server             |
| `dataset_run_url`  | String, nil         | URL to the run in Langfuse UI              |

**Methods:**

```ruby
result.successes                          # => Array<ItemResult> (no errors)
result.failures                           # => Array<ItemResult> (had errors)
result.format                             # => summary string
result.format(include_item_results: true) # => detailed per-item report
```

### ItemResult

One per item processed.

| Property         | Type                              | Description                |
| ---------------- | --------------------------------- | -------------------------- |
| `item`           | DatasetItemClient / ExperimentItem| Original input item        |
| `output`         | Object, nil                       | Task output (nil on error) |
| `trace_id`       | String, nil                       | Trace ID                   |
| `observation_id` | String, nil                       | Observation/span ID        |
| `evaluations`    | Array\<Evaluation\>               | Item-level scores          |
| `error`          | StandardError, nil                | Error if task failed       |

**Methods:**

```ruby
result.success?  # => true if no error
result.failed?   # => true if error present
```

## End-to-End Example

```ruby
client = Langfuse.client

# 1. Create a dataset
dataset = client.create_dataset(name: "support-qa")

# 2. Add items
[
  { q: "How do I reset my password?", a: "Go to Settings > Security > Reset Password" },
  { q: "What are your hours?", a: "Monday-Friday, 9am-5pm EST" }
].each do |pair|
  client.create_dataset_item(
    dataset_name: "support-qa",
    input: { question: pair[:q] },
    expected_output: { answer: pair[:a] }
  )
end

# 3. Define evaluators
accuracy = ->(input:, output:, expected_output:, item:, **) {
  match = output.to_s.downcase.include?(expected_output[:answer].to_s.downcase)
  Langfuse::Evaluation.new(name: "contains_answer", value: match, data_type: :boolean)
}

pass_rate = ->(item_results:) {
  passed = item_results.count(&:success?)
  Langfuse::Evaluation.new(name: "pass_rate", value: passed.to_f / item_results.size)
}

# 4. Run experiment
result = client.run_experiment(
  name: "support-bot-v1",
  dataset_name: "support-qa",
  task: ->(item) { generate_support_response(item.input[:question]) },
  evaluators: [accuracy],
  run_evaluators: [pass_rate],
  metadata: { model: "gpt-4o", temperature: 0.3 }
)

# 5. Inspect results
puts result.format(include_item_results: true)
puts "URL: #{result.dataset_run_url}"
```

## See Also

- [DATASETS.md](DATASETS.md) - Dataset CRUD operations
- [SCORING.md](SCORING.md) - Scoring guide
- [API_REFERENCE.md](API_REFERENCE.md) - Complete method reference
