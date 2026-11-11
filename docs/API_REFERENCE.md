# API Reference

Use `client = Langfuse.client`. Configuration defaults and lifecycle rules are in
[Configuration](CONFIGURATION.md). API-returned hashes use string keys.
Network methods can raise `Langfuse::ConfigurationError`, `UnauthorizedError`,
`NotFoundError`, or `ApiError`; invalid arguments can raise `ArgumentError`.
See [Error Handling](ERROR_HANDLING.md) for exceptions and retry behavior.

## Configuration and Lifecycle

| Method | Contract |
| --- | --- |
| `Langfuse.configure { |config| ... }` | Updates configuration; does not initialize tracing or replace the global provider. |
| `Langfuse.configuration` | Returns the current `Config`, initialized from environment defaults on first access. |
| `Langfuse.configuration = config` | Replaces configuration and resets existing SDK resources. |
| `Langfuse.client` | Returns the lazy singleton `Client`. |
| `Langfuse.configured?` | Local readiness check; no authentication request. |
| `Langfuse.tracer_provider` | Returns the internal provider; raises `ConfigurationError` for invalid enabled tracing. |
| `Langfuse.force_flush(timeout: 30)` | Attempts to export completed traces. |
| `Langfuse.flush_scores` / `client.flush_scores` | Attempts delivery of queued scores. |
| `Langfuse.shutdown(timeout: 30)` | Stops the client and provider; attempts final trace and score delivery. |
| `client.shutdown` | Stops this client's score and prompt-cache workers. |
| `Langfuse.reset!` | Shuts down resources and clears configuration; the next access rebuilds from environment defaults. |

`Langfuse::Config.new { |config| ... }` and `Langfuse::Client.new(config)` are
available for explicitly owned clients. Module-level tracing still uses the global
Langfuse configuration and provider. Config exposes `validate!`, `valid?`, and
`validate_tracing!` for local validation.

## Prompts

```ruby
client.get_prompt(name, version: nil, label: nil, fallback: nil, type: nil, cache_ttl: nil)
client.get_prompt_result(name, version: nil, label: nil, fallback: nil, type: nil, cache_ttl: nil)
client.refresh_prompt(name, version: nil, label: nil, cache_ttl: nil)
client.compile_prompt(name, variables: {}, version: nil, label: nil, fallback: nil, type: nil, cache_ttl: nil)
client.create_prompt(name:, prompt:, type:, config: {}, labels: [], tags: [], commit_message: nil)
client.update_prompt(name:, version:, labels:)
client.list_prompts(page: nil, limit: nil)
```

| Method | Return |
| --- | --- |
| `get_prompt`, `create_prompt`, `update_prompt` | `TextPromptClient` or `ChatPromptClient` |
| `get_prompt_result`, `refresh_prompt` | `PromptFetchResult` containing a prompt client and fetch metadata |
| `compile_prompt` | String for text, array of message hashes for chat |
| `list_prompts` | One page of metadata as `Array<Hash>` |

Choose either `version:` or `label:`. A fallback requires `type: :text` or `:chat`.
Per-call `cache_ttl:` must be a non-negative Integer; zero bypasses caching.
`create_prompt` creates a version; `update_prompt` replaces labels on an existing
version. See [Prompt Management](PROMPTS.md) for compilation and fallback semantics.

Both prompt clients expose:

- `name`, `version`, `type`, `prompt`, `config`, `labels`, `tags`, `commit_message`,
  `resolution_graph`, and `is_fallback`.
- `compile(**variables)`: compiled text or chat messages. Malformed chat placeholders
  raise `ArgumentError`.
- `variables`: unique Mustache references in source order. Invalid template syntax
  raises `Mustache::Parser::SyntaxError`.

`PromptFetchResult` exposes `prompt`, `name`, `version`, `label`, `logical_key`,
`storage_key`, `cache_status`, `source`, `fallback?`, and `to_h` (metadata only).
Cache status is `:hit`, `:miss`, `:stale`, `:refresh`, `:bypass`, or `:disabled`;
source is `:cache`, `:api`, or `:fallback`.

### Cache Operations

```ruby
client.prompt_cache_key(name, version: nil, label: nil)
client.invalidate_prompt_cache(name, version: nil, label: nil)
client.invalidate_prompt_cache_by_name(name)
client.clear_prompt_cache
client.prompt_cache_stats
client.validate_prompt_cache_backend!
```

`prompt_cache_key` returns `PromptCacheKey` with `name`, `version`, `label`,
`resolved_label`, `logical_key`, `storage_key`, and `to_h`. Stats return a hash;
unsupported counts are `nil`. See [Caching](CACHING.md) for invalidation scope and
backend validation.

```ruby
warmer = Langfuse::CacheWarmer.new(client: nil) # Defaults to Langfuse.client.
warmer.warm(prompt_names, versions: {}, labels: {})
warmer.warm!(prompt_names, versions: {}, labels: {})
warmer.warm_all(default_label: "production", versions: {}, labels: {})
warmer.cache_enabled?
warmer.cache_stats
```

Warm methods return `{ success: [names], failed: [{ name:, error: }] }`; errors are
strings. `warm!` raises `CacheWarmingError` on any failure. `warm_all` discovers one
page of names only. Selectors are hashes keyed by prompt name.

## Tracing

```ruby
Langfuse.observe(name, attrs = {}, as_type: :span, trace_id: nil, **attribute_keywords, &block)
Langfuse.start_observation(name, attrs = {}, as_type: :span, trace_id: nil,
                          parent_span_context: nil, start_time: nil, skip_validation: false)
Langfuse.create_trace_id(seed: nil)
```

The first two return an observation; `observe` with a block returns the block value
and ends the observation. `start_observation` is stateful; it does not activate the
span or run a block. `start_time` accepts a Time or Unix timestamp in nanoseconds.
Use a positional attributes hash with this method. `skip_validation` is a type
validation bypass used internally by child observations.

`trace_id` must be a nonzero lowercase 32-character hexadecimal String and cannot
be combined with `parent_span_context`. Explicit trace IDs start new roots.
`create_trace_id` returns a random ID or one derived deterministically from `seed`.
Types and context behavior are described in [Tracing](TRACING.md).

### Observation Objects

```ruby
observation.update(attrs)
observation.update_trace(attrs)
observation.start_observation(name, attrs = {}, as_type: :span, &block)
observation.event(name:, input: nil, level: "default")
observation.end(end_time: nil)
observation.score_trace(name:, value:, comment: nil, metadata: nil, data_type: :numeric)
```

Readers are `id`, `trace_id`, `trace_url`, `type`, `otel_span`, `otel_tracer`, and
`current_span` (the wrapped OpenTelemetry span). URL lookup can return `nil`.
`update` and `update_trace` return the observation. Child creation returns the child
or its block's value. `score_trace` queues a score asynchronously.

| Attribute group | Fields |
| --- | --- |
| Observation | `input`, `output`, `metadata`, `level`, `status_message`, `version`, `environment` |
| Model call | `model`, `model_parameters`, `usage_details`, `cost_details`, `completion_start_time`, `prompt` |
| Trace via `update_trace` | `name`, `user_id`, `session_id`, `version`, `release`, `input`, `output`, `metadata`, `tags`, `public`, `environment` |

Set fields with `update(...)`. All observations also have `input=`, `output=`,
`metadata=`, and `level=`. Generations and embeddings add `model=`,
`model_parameters=`, and `usage_details=`; `usage=` is deprecated. Generations
add `cost_details=`. These setters do not imply corresponding readers.

Use `input`, `output`, and `total` keys for aggregate usage/cost details. `prompt`
accepts a prompt client or a hash with `name`, `version`, and `is_fallback`.
Levels are `DEBUG`, `DEFAULT`, `WARNING`, and `ERROR`. `end_time` accepts a Time or
Unix timestamp in nanoseconds. Standalone event observations end at creation.

Attribute objects can replace hashes: `Langfuse::Types::SpanAttributes`,
`GenerationAttributes` (adds model-call fields), and `TraceAttributes`. Their
constructors accept the corresponding keywords, default to nil, and expose `to_h`.

### Propagation and Filtering

```ruby
Langfuse.propagate_attributes(
  user_id: nil, session_id: nil, metadata: nil, version: nil, tags: nil,
  trace_name: nil, release: nil, environment: nil, skills_available: nil,
  attach_skills: nil, as_baggage: false
) { perform_work }

Langfuse.discover_skills(dir:)
Langfuse.default_export_span?(span)
Langfuse.langfuse_span?(span)
Langfuse.genai_span?(span)
Langfuse.known_llm_instrumentor?(span)
```

Propagation requires a block and returns its value. See [Tracing](TRACING.md#propagate-trace-attributes)
for value constraints, merging, and baggage setup, and
[Skill Availability](TRACING.md#skill-availability) for discovery and scope rules.
Filter predicates return Booleans and retain `is_default_export_span`,
`is_langfuse_span`, `is_genai_span`, and `is_known_llm_instrumentor` aliases.

Export masking uses `MaskOtelSpansParams`, `OtelSpanIdentifier`, `OtelSpanData`,
`OtelSpanPatch`, and `MaskOtelSpansResult`. See the
[masking contract](TRACING.md#export-stage-masking) for fields and failure behavior.

## Scoring

`client.create_score` and `client.create_score!` accept the same keywords:

```ruby
client.create_score(
  name:, value:, id: nil, timestamp: nil, trace_id: nil, session_id: nil,
  observation_id: nil, comment: nil, metadata: nil, environment: nil,
  data_type: :numeric, dataset_run_id: nil, config_id: nil
)

client.score_active_observation(name:, value:, comment: nil, metadata: nil, data_type: :numeric)
client.score_active_trace(name:, value:, comment: nil, metadata: nil, data_type: :numeric)
client.flush_scores
```

All four score-creation methods and `flush_scores` also exist on `Langfuse`.
`timestamp` accepts a Time or String and defaults to now. An omitted, nil, or empty
`id` generates a UUID.
`create_score` and the active-context helpers return `nil`. With telemetry enabled,
the active-context helpers raise `ArgumentError` if no valid span is active. `create_score!` returns
the accepted score ID or nil when telemetry is disabled. Invalid values raise
`ArgumentError`; synchronous transport or rejection failures raise an `ApiError`
subclass. See [Scoring](SCORING.md) for types, associations, sampling, retry identity,
and batch delivery limits.

## Data Access

These calls return parsed response hashes, including `data` and any pagination
`meta`. List calls return one page; callers advance the cursor themselves.
Observation `input` and `output` remain JSON-encoded strings inside that response.

```ruby
client.list_observations(
  from_start_time: nil, to_start_time: nil, trace_id: nil,
  fields: nil, cursor: nil, limit: nil, filter: nil,
  name: nil, user_id: nil, type: nil, level: nil,
  parent_observation_id: nil, is_root_observation: nil,
  environment: nil, session_id: nil, version: nil, expand_metadata: nil
)

client.query_metrics(query:)

client.list_scores(
  limit: nil, cursor: nil, fields: nil, id: nil, name: nil, source: nil,
  data_type: nil, environment: nil, config_id: nil, queue_id: nil,
  author_user_id: nil, value: nil, value_min: nil, value_max: nil,
  trace_id: nil, session_id: nil, observation_id: nil, experiment_id: nil,
  from_timestamp: nil, to_timestamp: nil
)
```

Observation reads require either a nonempty `trace_id` or both start-time bounds;
otherwise they raise `ArgumentError`. Time bounds accept Time objects or ISO 8601
strings. `environment` is an array of strings. `type` uses uppercase names such as
`GENERATION`; `fields` is a comma-separated selection from `core`, `basic`, `time`,
`io`, `metadata`, `model`, `usage`, `prompt`, `metrics`, and `trace_context`.
`filter` is a JSON string of structured filters and takes precedence over individual
filters at the backend. `expand_metadata` is a comma-separated list of metadata keys.

Metrics `query` accepts a Hash (JSON-encoded by the SDK) or a pre-encoded JSON String.
Other types raise `ArgumentError`. The server validates the query schema.

Score filters use comma-separated strings for IDs, names, types, sources, and
environments. `fields` adds `details`, `subject`, or `annotation` to core fields.
Choose one subject family: trace, session, or experiment. `observation_id` requires
`trace_id`. `value` requires a single numeric, boolean, or categorical `data_type`;
`value_min` and `value_max` require `NUMERIC`. These are backend constraints.

See [Data Access](DATA_ACCESS.md) for pagination, metrics queries, and verification.

### Legacy Trace Reads

```ruby
client.list_traces(
  page: nil, limit: nil, user_id: nil, name: nil, session_id: nil,
  from_timestamp: nil, to_timestamp: nil, order_by: nil,
  tags: nil, version: nil, release: nil, environment: nil, fields: nil, filter: nil
)
client.get_trace(id)
```

`list_traces` returns one page as `Array<Hash>`; `get_trace` returns a Hash.
Use observation reads for current trace traversal.

## Datasets

```ruby
client.create_dataset(name:, description: nil, metadata: nil)
client.get_dataset(name)
client.list_datasets(page: nil, limit: nil)

client.create_dataset_item(
  dataset_name:, input: nil, expected_output: nil, metadata: nil, id: nil,
  source_trace_id: nil, source_observation_id: nil, status: nil
)
client.get_dataset_item(id)
client.list_dataset_items(
  dataset_name:, page: nil, limit: nil, source_trace_id: nil, source_observation_id: nil
)
client.delete_dataset_item(id)

client.create_dataset_run_item(
  dataset_item_id:, run_name:, trace_id: nil, observation_id: nil,
  metadata: nil, run_description: nil
)
client.get_dataset_run(dataset_name:, run_name:)
client.list_dataset_runs(dataset_name:, page: nil, limit: nil)
client.delete_dataset_run(dataset_name:, run_name:)
```

Create/get dataset methods return `DatasetClient`; create/get item methods return
`DatasetItemClient`. Dataset lists return one page of metadata hashes. Item and run
lists fetch all pages unless `page:` is supplied; `limit:` is the page size.
Item lists return wrappers, run lists return hashes. Run-item creation and run reads
return hashes. Deletes return nil; only item deletion treats 404 as success.

```ruby
item.link(trace_id:, run_name:, observation_id: nil, metadata: nil, run_description: nil)
item.run(run_name:, run_description: nil, run_metadata: nil) { |observation| observation.update(output: "Done") }
```

`link` returns the created run-item hash; `run` returns the block value after tracing
and linking. See [Datasets](DATASETS.md) for object readers and error behavior.

## Experiments

```ruby
client.run_experiment(
  name:, task:, data: nil, dataset_name: nil, description: nil,
  evaluators: [], run_evaluators: [], metadata: nil, run_name: nil
)

dataset.run_experiment(
  name:, task:, description: nil, evaluators: [], run_evaluators: [],
  metadata: nil, run_name: nil
)

Langfuse::Evaluation.new(
  name:, value:, comment: nil, data_type: :numeric, config_id: nil, metadata: nil
)
```

Provide exactly one of `data` or `dataset_name` to the client method. The dataset
method uses its current items. Both return `ExperimentResult`. Evaluations expose
their constructor fields and `to_h`; only numeric, boolean, and categorical types
are accepted. See [Experiments](EXPERIMENTS.md) for callable contracts, result
objects, persistence limits, and v4 attribution.

## URLs

```ruby
client.project_id
client.trace_url(trace_id)
client.dataset_url(dataset_id)
client.dataset_run_url(dataset_id:, dataset_run_id:)
```

These return strings or nil if project lookup fails. The client attempts project
lookup once and caches the outcome; creating an observation alone does not require
this request.
