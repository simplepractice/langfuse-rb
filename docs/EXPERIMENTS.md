# Experiments

`run_experiment` executes a task sequentially over dataset or local items, records
traces, runs evaluators, and attempts to deliver their scores.

## Run an Experiment

```ruby
accuracy = lambda do |input:, output:, expected_output:, item:|
  Langfuse::Evaluation.new(name: "correct", value: output == expected_output, data_type: :boolean)
end

result = Langfuse.client.run_experiment(
  name: "uppercase", data: [{ input: "ruby", expected_output: "RUBY" }],
  task: ->(item) { item.input.upcase }, evaluators: [accuracy]
)

puts result.format
```

Provide exactly one of `data:` or `dataset_name:`. Local hashes accept symbol or
string keys and become `ExperimentItem` objects with `input`, `expected_output`,
and `metadata`. Nested local data keeps its original keys. Server-fetched JSON
uses string keys. `data:` can also contain `DatasetItemClient` objects.

For a managed dataset:

```ruby
result = Langfuse.client.run_experiment(
  name: "qa-v1", dataset_name: "qa-eval",
  task: ->(item) { answer_question(item.input.fetch("question")) }
)
```

`answer_question` is an application method. If a dataset is already loaded, use
`dataset.run_experiment(name:, task:, ...)` to run its current `items`.
The runner does not filter archived items; pass `data: dataset.items.select(&:active?)`
when only active items should run.

Optional arguments are `description:`, `metadata:`, `run_name:`, `evaluators:`, and
`run_evaluators:`. The default run name is `"name - timestamp"`.

## Evaluators

Item evaluators receive `input:`, `output:`, `expected_output:`, and `item:`. An
explicit `metadata:` keyword parameter receives item metadata as well. They may
return an `Evaluation`, a hash of evaluation arguments, an array of either, or
`nil` to omit a result.

```ruby
Langfuse::Evaluation.new(
  name: "quality", value: 0.85, comment: "Mostly correct",
  data_type: :numeric, config_id: nil, metadata: { evaluator: "rules-v1" }
)
```

Evaluation types are `:numeric`, `:boolean`, and `:categorical`. Text notes and
corrections belong to the general [Scoring](SCORING.md) API.

Run evaluators receive all results through `item_results:`:

```ruby
completion_rate = lambda do |item_results:|
  completed = item_results.count(&:success?)
  rate = item_results.empty? ? 0.0 : completed.fdiv(item_results.size)
  Langfuse::Evaluation.new(name: "completion_rate", value: rate)
end
```

Pass this callable in `run_evaluators: [completion_rate]`. Run-level scores are
persisted only when a dataset run ID is available. Local-data run evaluations are
returned but are not persisted as dataset-run scores.

## Results and Failures

| Object | Fields and methods |
| --- | --- |
| `ExperimentResult` | `name`, `run_name`, `description`, `item_results`, `run_evaluations`, `experiment_id`, `dataset_run_id`, `dataset_run_url` |
| `ItemResult` | `item`, `output`, `trace_id`, `observation_id`, `evaluations`, `error`, `success?`, `failed?` |

`result.successes` and `result.failures` group items by task error, not by evaluation
score or confirmed persistence. `result.format(include_item_results: true)` adds
per-item detail to the summary.

A task exception is recorded on its `ItemResult`; later items continue. Exceptions
raised by evaluator calls, score delivery failures, and dataset-link failures are
logged. They do not by themselves mark a task result as failed. Invalid evaluation
hashes returned by item evaluators can raise during normalization. Validate evaluator
return values and inspect API readback when persistence is required.

## Langfuse v4 Attribution

The item root and its children share the experiment ID, run name, item ID, item
root observation ID, experiment and item metadata, and `sdk-experiment` environment.
Expected output and run description stay on the root. Item scores target both the
trace and item root observation.

A dataset-backed run uses the first resolved server run ID. If its first link fails,
it keeps a generated fallback experiment ID; `dataset_run_id` and `dataset_run_url`
remain `nil`. Local-data runs use one generated experiment ID and input-derived item
IDs. Use [Data Access](DATA_ACCESS.md) to verify stored observations and scores.
