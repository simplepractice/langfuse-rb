# Datasets

A dataset contains inputs, optional expected outputs, and metadata for evaluations.
Use [Experiments](EXPERIMENTS.md) to run tasks and evaluators over its items.

## Create and Fetch

```ruby
client = Langfuse.client

dataset = client.create_dataset(
  name: "qa-eval", description: "Question-answering examples", metadata: { version: 1 }
)
item = client.create_dataset_item(
  dataset_name: dataset.name,
  input: { question: "What is Ruby?" },
  expected_output: { answer: "A programming language" },
  metadata: { difficulty: "easy" }
)

dataset = client.get_dataset("qa-eval")
item = client.get_dataset_item(item.id)
```

Names can contain folder paths, such as `evaluation/qa-eval`. Pass an item's `id:`
to `create_dataset_item` to upsert it. Optional `source_trace_id` and
`source_observation_id` record where an item originated; `status:` accepts
`:active` or `:archived`.

API-returned nested input, expected-output, and metadata hashes have string keys:
`item.input.fetch("question")`.

| Object | Readers |
| --- | --- |
| `DatasetClient` | `id`, `name`, `description`, `metadata`, `created_at`, `updated_at`, `url`, `items` |
| `DatasetItemClient` | `id`, `dataset_id`, `input`, `expected_output`, `metadata`, `source_trace_id`, `source_observation_id`, `status`, `created_at`, `updated_at` |

Timestamps are `Time` or `nil`. Items expose `active?` and `archived?`; `status`
is `"ACTIVE"` or `"ARCHIVED"`. `dataset.items` memoizes wrapped items from the
response, or fetches them through `list_dataset_items` if none were embedded.
Refetch the dataset to obtain a new view of its items.

## List and Delete

```ruby
# One page of dataset metadata (Array<Hash>).
datasets = client.list_datasets(page: 1, limit: 20)

# All item pages (Array<DatasetItemClient>).
items = client.list_dataset_items(dataset_name: "qa-eval")

# One page; source_trace_id and source_observation_id can also filter this call.
items = client.list_dataset_items(dataset_name: "qa-eval", page: 1, limit: 20)

client.delete_dataset_item(item.id)
```

Deleting a missing item succeeds. `list_dataset_items` and `list_dataset_runs`
automatically paginate unless `page:` is supplied. Their `limit:` controls page
size, not the total result count. `list_datasets` always returns just one page.

## Link Items to Runs

To associate an existing trace with a dataset item:

```ruby
item.link(trace_id: trace_id, observation_id: observation_id, run_name: "qa-v2")
```

`observation_id`, `metadata`, and `run_description` are optional. A lower-level
helper creates a trace, flushes it, and links the item after the block:

```ruby
output = item.run(run_name: "qa-v2", run_metadata: { variant: "candidate" }) do |span|
  answer = answer_question(item.input.fetch("question")) # Your application method.
  span.update(output: answer)
  answer
end
```

`item.run` returns the block value. A task exception is re-raised after flushing
and attempting the link; a link failure can also raise. These helpers create run
links but do not add v4 experiment attribution. Use `run_experiment` when the run
must appear as a complete experiment in Langfuse.

## Manage Runs

```ruby
run = client.get_dataset_run(dataset_name: "qa-eval", run_name: "qa-v2")
runs = client.list_dataset_runs(dataset_name: "qa-eval")
client.delete_dataset_run(dataset_name: "qa-eval", run_name: "qa-v2")
```

Run reads return hashes with string keys; `get_dataset_run` includes linked run
items. Deleting a missing run raises `Langfuse::NotFoundError`, unlike item deletion.
See [API Reference](API_REFERENCE.md#datasets) for all parameters.
