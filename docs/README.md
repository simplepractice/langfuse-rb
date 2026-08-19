# Langfuse Ruby SDK Documentation

Use this page to find the correct guide for your task.
The guides explain workflows and limits.
[API_REFERENCE.md](API_REFERENCE.md) contains the exact public method signatures.

## Start Here

1. [Getting Started](GETTING_STARTED.md) — install, configure, create a useful trace, and verify backend ingestion
2. [Prompt Management](PROMPTS.md) — fetch, inspect, compile, version, and cache prompts
3. [Tracing](TRACING.md) — model observation trees, propagate context, mask data, and integrate OpenTelemetry
4. [Scoring](SCORING.md) — attach synchronous or asynchronous evaluation and feedback signals
5. [Data Access](DATA_ACCESS.md) — query current observations, metrics, and scores through the SDK or CLI

## Guides by Task

| Task | Canonical guide |
| --- | --- |
| Configure keys, batching, sampling, masking, exporters, or telemetry controls | [Configuration](CONFIGURATION.md) |
| Add tracing to a workflow | [Tracing](TRACING.md) |
| Verify newly exported records | [Data Access](DATA_ACCESS.md) |
| Fetch or compile managed prompts | [Prompt Management](PROMPTS.md) |
| Tune prompt caching or stale-while-revalidate | [Caching](CACHING.md) |
| Record user feedback or evaluation results | [Scoring](SCORING.md) |
| Build dataset-backed evaluations | [Datasets](DATASETS.md) and [Experiments](EXPERIMENTS.md) |
| Integrate controllers, services, and jobs | [Rails](RAILS.md) |
| Test trace output without network access | [Testing Tracing](TESTING.md) |
| Diagnose configuration, API, or cache failures | [Error Handling](ERROR_HANDLING.md) |
| Move hardcoded prompts into Langfuse | [Migration](MIGRATION.md) |

## Reference

- [API Reference](API_REFERENCE.md) — exact methods, parameters, return values, and exceptions
- [Configuration](CONFIGURATION.md) — option and environment-variable reference
- [Architecture](ARCHITECTURE.md) — contributor-facing components, ownership, and data flow
- [Changelog](../CHANGELOG.md) — release behavior changes

## Production Checklist

- Use one trace for each self-contained unit of work.
- Use stable, action-oriented observation names.
- Put meaningful input and output on the root observation.
- Record model, usage, and prompt details on generation observations.
- Set `environment` to keep development and staging records out of production analysis.
- Configure masking before tracing starts when payloads can contain sensitive data.
- Select asynchronous `create_score` or synchronous `create_score!` for the required delivery contract.
- Use bounded observation reads and cursor pagination for data extraction.
- Verify one real trace and score in the target Langfuse project before deployment.

A normal process exit flushes pending data.
The SDK resets background workers after Ruby `fork`.
An abrupt termination such as `SIGKILL` cannot run flush callbacks.
