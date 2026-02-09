# Langfuse Ruby SDK — Documentation

## Foundations

Core concepts you need before using any feature.

- **[Getting Started](GETTING_STARTED.md)** — Install the gem, configure credentials, send your first trace
- **[Configuration](CONFIGURATION.md)** — All `Langfuse.configure` options: keys, timeouts, cache backends, SWR

## Core Features

The three primitives of the SDK.

- **[Prompts](PROMPTS.md)** — Fetch, compile, and version-manage text and chat prompts
- **[Tracing](TRACING.md)** — Nested spans, RAG patterns, OpenTelemetry integration
- **[Scoring](SCORING.md)** — Attach quality scores to traces and observations

## Evaluation

Systematic testing of LLM behavior.

- **[Datasets](DATASETS.md)** — Create and manage evaluation datasets
- **[Experiments](EXPERIMENTS.md)** — Run evaluations against datasets with the experiment runner

## Production

Patterns for real-world deployments.

- **[Caching](CACHING.md)** — In-memory and Rails.cache backends, SWR, stampede protection
- **[Error Handling](ERROR_HANDLING.md)** — Exception types, retry behavior, fallback strategies
- **[Rails Integration](RAILS.md)** — Initializers, controller tracing, testing helpers
- **[Migration Guide](MIGRATION.md)** — Move from hardcoded prompts to Langfuse-managed prompts

## Reference

- **[API Reference](API_REFERENCE.md)** — Complete method reference for every public class
- **[Architecture](ARCHITECTURE.md)** — Internal design: layers, threading, cache architecture
