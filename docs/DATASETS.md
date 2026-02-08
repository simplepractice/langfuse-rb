# Datasets

Curated test sets for evaluating LLM pipelines. Datasets let you define input/expected-output pairs and systematically compare runs.

## Overview

A **dataset** is a named collection of **items**, each containing an input and optionally an expected output. You create dataset items manually, or from production traces. Then you run experiments against the dataset to measure how your LLM pipeline performs.

Key objects:

- `DatasetClient` — wraps a dataset with its items and metadata
- `DatasetItemClient` — wraps a single item (input, expected output, status)

## Creating Datasets

```ruby
client = Langfuse.client

dataset = client.create_dataset(
  name: "qa-eval",
  description: "Question-answering evaluation set",
  metadata: { domain: "support", version: 1 }
)
```

| Parameter     | Type   | Required | Description              |
| ------------- | ------ | -------- | ------------------------ |
| `name`        | String | Yes      | Dataset name             |
| `description` | String | No       | Human-readable description |
| `metadata`    | Hash   | No       | Arbitrary key-value pairs  |

**Returns:** `DatasetClient`

## Fetching Datasets

```ruby
dataset = client.get_dataset("qa-eval")

dataset.name        # => "qa-eval"
dataset.description # => "Question-answering evaluation set"
dataset.metadata    # => { "domain" => "support", "version" => 1 }
dataset.id          # => "clx..."
dataset.url         # => "https://cloud.langfuse.com/project/{pid}/datasets/clx..."
dataset.created_at  # => Time
dataset.updated_at  # => Time
```

Folder paths are supported: `client.get_dataset("evaluation/qa-dataset")`.

## Listing Datasets

```ruby
# First page (default)
datasets = client.list_datasets

# With pagination
datasets = client.list_datasets(page: 2, limit: 10)
```

| Parameter | Type    | Required | Default | Description      |
| --------- | ------- | -------- | ------- | ---------------- |
| `page`    | Integer | No       | -       | Page number      |
| `limit`   | Integer | No       | -       | Results per page |

**Returns:** `Array<Hash>` of dataset metadata

## Creating Items

```ruby
item = client.create_dataset_item(
  dataset_name: "qa-eval",
  input: { question: "What is Ruby?" },
  expected_output: { answer: "A programming language" },
  metadata: { difficulty: "easy" }
)
```

| Parameter               | Type   | Required | Description                                |
| ----------------------- | ------ | -------- | ------------------------------------------ |
| `dataset_name`          | String | Yes      | Parent dataset name                        |
| `input`                 | Object | No       | Input data                                 |
| `expected_output`       | Object | No       | Expected output for evaluation             |
| `metadata`              | Hash   | No       | Arbitrary metadata                         |
| `id`                    | String | No       | Explicit ID (enables upsert behavior)      |
| `source_trace_id`       | String | No       | Trace that produced this item              |
| `source_observation_id` | String | No       | Observation that produced this item        |
| `status`                | Symbol | No       | `:active` or `:archived`                   |

**Returns:** `DatasetItemClient`

### DatasetItemClient Properties

| Property                | Type        | Description                    |
| ----------------------- | ----------- | ------------------------------ |
| `id`                    | String      | Unique identifier              |
| `dataset_id`            | String      | Parent dataset ID              |
| `input`                 | Object      | Input data                     |
| `expected_output`       | Object      | Expected output                |
| `metadata`              | Hash        | Key-value metadata             |
| `source_trace_id`       | String, nil | Linked source trace            |
| `source_observation_id` | String, nil | Linked source observation      |
| `status`                | String      | `"ACTIVE"` or `"ARCHIVED"`    |
| `created_at`            | Time, nil   | Creation timestamp             |
| `updated_at`            | Time, nil   | Last updated timestamp         |

Convenience methods:

```ruby
item.active?    # => true
item.archived?  # => false
```

## Fetching Items

```ruby
# By ID
item = client.get_dataset_item("item-uuid-123")

# List all items (auto-paginates)
items = client.list_dataset_items(dataset_name: "qa-eval")

# Single page
items = client.list_dataset_items(dataset_name: "qa-eval", page: 1, limit: 20)

# Filter by source
items = client.list_dataset_items(
  dataset_name: "qa-eval",
  source_trace_id: "trace-abc"
)
```

| Parameter               | Type    | Required | Description                              |
| ----------------------- | ------- | -------- | ---------------------------------------- |
| `dataset_name`          | String  | Yes      | Dataset name                             |
| `page`                  | Integer | No       | Page number (nil = fetch all pages)      |
| `limit`                 | Integer | No       | Results per page                         |
| `source_trace_id`       | String  | No       | Filter by source trace                   |
| `source_observation_id` | String  | No       | Filter by source observation             |

**Returns:** `Array<DatasetItemClient>`

You can also access items through the dataset directly:

```ruby
dataset = client.get_dataset("qa-eval")
dataset.items  # => Array<DatasetItemClient> (lazy-loaded)
```

## Deleting Items

```ruby
client.delete_dataset_item("item-uuid-123")
```

Idempotent — 404 is treated as success.

## Linking Items to Traces

### Manual Linking

Link a dataset item to a trace after running your pipeline:

```ruby
item.link(
  trace_id: "abc123",
  run_name: "qa-v2",
  observation_id: "obs456",       # optional
  metadata: { model: "gpt-4o" },  # optional
  run_description: "GPT-4o run"   # optional
)
```

### Traced Execution with `item.run`

Execute a block within a traced context that automatically links to the dataset item:

```ruby
item = client.get_dataset_item("item-uuid-123")

output = item.run(run_name: "qa-v2") do |span|
  # span is a traced observation — update it as needed
  result = my_llm_call(item.input)
  span.update(output: result)
  result
end
```

| Parameter        | Type   | Required | Description                  |
| ---------------- | ------ | -------- | ---------------------------- |
| `run_name`       | String | Yes      | Run name for grouping        |
| `run_description`| String | No       | Run description              |
| `run_metadata`   | Hash   | No       | Metadata for the trace       |

The block receives a traced span. On completion (or error), the trace is flushed and the item is linked automatically.

## See Also

- [EXPERIMENTS.md](EXPERIMENTS.md) - Run systematic evaluations against datasets
- [SCORING.md](SCORING.md) - Score traces and observations
- [API_REFERENCE.md](API_REFERENCE.md) - Complete method reference
