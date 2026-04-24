# Langfuse Ruby SDK Documentation

This is the consumer hub. Start here unless you are already looking for a specific reference page.

## Start Here

1. **[Getting Started](GETTING_STARTED.md)** — Rails-first first run: install, configure, fetch a prompt, send a real trace
2. **[Prompts](PROMPTS.md)** — Fetch, compile, version, and fall back safely
3. **[Tracing](TRACING.md)** — Root observations, nested generations, events, propagation, and OpenTelemetry ownership
4. **[Scoring](SCORING.md)** — Add evaluation and feedback signals to traces and observations
5. **[Rails](RAILS.md)** — Applied controller, service, job, testing, and operational patterns

## By Intent

### First Run

- **[Getting Started](GETTING_STARTED.md)** — The shortest path from zero to a visible prompt + trace
- **[Prompts](PROMPTS.md)** — The next thing most consumers need after installation
- **[Tracing](TRACING.md)** — The actual tracing lifecycle, without the hand-wavy OpenTelemetry claims

### Instrument an App

- **[Tracing](TRACING.md)** — Observation hierarchy, propagation, background jobs, explicit global install
- **[Rails](RAILS.md)** — Rails-specific patterns for controllers, services, jobs, and tests
- **[Scoring](SCORING.md)** — Capture quality signals after a trace exists

### Production Hardening

- **[Configuration](CONFIGURATION.md)** — Config surface, tracing ownership, export filtering, environment defaults
- **[Caching](CACHING.md)** — Prompt cache backends, stale-while-revalidate, cache warming
- **[Error Handling](ERROR_HANDLING.md)** — Failure modes, retry boundaries, debugging
- **[Migration Guide](MIGRATION.md)** — Move hardcoded prompts into Langfuse-managed prompts without breaking runtime behavior

### Evaluation

- **[Datasets](DATASETS.md)** — Dataset primitives and management
- **[Experiments](EXPERIMENTS.md)** — Experiment runner workflows

### Reference

- **[API Reference](API_REFERENCE.md)** — Exact public signatures and types
- **[Configuration](CONFIGURATION.md)** — Option-by-option config reference
- **[Architecture](ARCHITECTURE.md)** — Implementation and internal design reference, not required for the first run
