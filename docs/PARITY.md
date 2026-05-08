# SDK Parity Matrix

This matrix compares `langfuse-rb` against the local sibling SDKs checked into this repository:

- Ruby: `lib/langfuse/**`, version `0.10.1`
- JS: `langfuse-js/packages/**`, package version `5.3.0`
- Python: `langfuse-python/langfuse/**`, package version `4.6.0b1`

The goal is not raw feature-count parity. Ruby should stay framework-agnostic, dependency-light, and flat-client-first. Generated manager trees from JS/Python are evidence for API behavior, not a mandate to copy their public shape.

## Shipped Now

| Area | JS/Python evidence | Ruby status |
| --- | --- | --- |
| SDK identity headers | JS `LangfuseClient` and generated core client pass `X-Langfuse-Sdk-Name` / `X-Langfuse-Sdk-Version`; Python `client_wrapper.py` sets the same REST headers. Both OTLP exporters also send lower-case SDK identity headers. | `Langfuse::SdkHeaders` now centralizes REST and OTLP identity headers. REST includes `X-Langfuse-Sdk-Name`, `X-Langfuse-Sdk-Version`, and `X-Langfuse-Public-Key`; OTLP includes `x-langfuse-sdk-name`, `x-langfuse-sdk-version`, and `x-langfuse-public-key`. |
| Prompt deletion | JS `prompt.delete(name, { version, label })` calls generated DELETE `/api/public/v2/prompts/{promptName}`; Python generated `prompts.delete` exposes the same endpoint. | `client.delete_prompt(name, version: nil, label: nil)` deletes prompt versions and invalidates all cached variants for that prompt name. Ruby returns `nil` for 204 responses instead of leaking transport details. |
| Media references | JS and Python expose `LangfuseMedia`, deterministic reference strings, reference parsing, reference resolution, and media upload APIs. | `Langfuse::Media` / `Langfuse::LangfuseMedia` support bytes, file, and base64 data URI input; deterministic media IDs; reference string parsing; nested reference resolution to base64 data URIs; and `get_media`, `get_media_upload_url`, `patch_media`, `upload_media`. |
| Sessions | JS/Python generated clients expose `/api/public/sessions` list and get. | `client.list_sessions(**filters)` and `client.get_session(session_id)` are flat read APIs. |
| Observations v2 | JS/Python generated clients expose GET `/api/public/v2/observations`. | `client.list_observations(**filters)` is a thin v2 read API with Ruby snake_case query keys converted to API camelCase. |
| Scores v2 | JS/Python generated clients expose GET `/api/public/v2/scores` and GET by score ID. | `client.list_scores(**filters)` and `client.get_score(score_id)` cover v2 readback while existing score creation remains batched and flat. |
| Score configs | JS/Python generated clients expose create/list/get/update under `/api/public/score-configs`. | `client.create_score_config`, `list_score_configs`, `get_score_config`, and `update_score_config` provide thin admin access with recursive snake_case to camelCase body conversion. |
| Models | JS/Python generated clients expose create/list/get/delete under `/api/public/models`. | `client.create_model`, `list_models`, `get_model`, and `delete_model` provide thin model admin access. |
| Metrics v2 | JS/Python generated clients expose GET `/api/public/v2/metrics`. | `client.query_metrics(query:)` accepts a JSON string or a Ruby hash encoded as the API `query` parameter. |
| Health | JS/Python generated clients expose GET `/api/public/health`. | `client.health` exposes the same check. |

## Separate Issues

These gaps are real, but they are not the same kind of work as AAI-129.

| Gap | Why separate |
| --- | --- |
| Full generated REST resource tree: annotation queues, comments, organizations, projects, LLM connections, blob storage integrations, SCIM, prompt-version namespace, trace delete/update, OpenTelemetry generated namespace | Shipping all of this as hand-written flat Ruby methods would either bloat the SDK or recreate generated-client machinery under another name. Each surface needs a Rails-facing use case before it belongs in the public Ruby client. |
| Experiment/eval ergonomics beyond the current runner | The useful work is run lifecycle, result comparison, and score attachment around real eval workflows. That coordinates with AAI-6 rather than landing as generic API breadth here. |
| Automatic media extraction from tracing payloads | JS/Python include task managers or media services that walk payloads and upload media in the background. Ruby now has the safe primitives; automatic span-payload rewriting needs a separate design because it changes tracing hot-path behavior. |
| Deeper v4 ingestion semantics | This branch aligns SDK identity headers and keeps existing v4-shaped observation primitives. Any additional ingestion-contract work should coordinate with AAI-67 rather than expanding this PR past observable parity. |

## Deferred

| Gap | Reason |
| --- | --- |
| Generated client machinery | Adds maintenance and dependency weight that conflicts with the current Ruby SDK design. Thin flat APIs are enough for the high-value Rails workflows. |
| Async media upload manager | Ruby already has explicit upload primitives. A background queue would need lifecycle, shutdown, retry, and error-reporting decisions. That is real architecture, not a parity checkbox. |
| Framework integrations copied from JS/Python | Ruby should stay framework-agnostic. Rails examples and cache support belong here; Rails as a gem dependency does not. |

## Not Applicable To Ruby

| JS/Python shape | Ruby decision |
| --- | --- |
| JS nested managers such as `langfuse.prompt.delete` or generated `client.prompts.delete` | Ruby keeps the flat API: `client.delete_prompt`. |
| Python decorator/context APIs copied literally | Ruby already exposes block/stateful observation APIs that match Ruby idioms better than decorator mimicry. |
| OpenAI/LangChain framework packages as SDK dependencies | Integrations can exist outside the core gem. The core SDK stays dependency-light. |
| Browser or Node-specific media objects | Ruby media input is bytes, file path, or base64 data URI. |

## Validation Map

| Requirement | Evidence |
| --- | --- |
| Local unit coverage | `spec/langfuse/api_client_spec.rb`, `spec/langfuse/client_spec.rb`, `spec/langfuse/media_spec.rb`, `spec/langfuse/otel_setup_spec.rb` |
| Client to ApiClient mocked HTTP coverage | WebMock specs assert REST paths, query/body mapping, cache invalidation, media upload PUT, and 204 delete semantics. |
| YARD docs for public methods | New public methods have YARD docs in `ApiClient`, delegated client docs, and consumer docs in `API_REFERENCE.md`. |
| Live platform validation | Use a local scratchpad verifier with Langfuse credentials plus Langfuse CLI discovery output in the PR evidence. |
| Caveats | This matrix is committed so the PR states what shipped, what did not ship, and why. |
