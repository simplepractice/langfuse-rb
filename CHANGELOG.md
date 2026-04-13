# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Custom/deterministic trace ID support via `Langfuse.create_trace_id(seed:)` (#74)
- `trace_id:` keyword on `Langfuse.observe` and `Langfuse.start_observation` for attaching observations to a specific trace
- Cross-SDK deterministic IDs: same seed produces the same trace ID in Ruby, Python, and JS SDKs (SHA-256 based)
- PII safety warnings in YARD docs for seed parameters

### Changed
- **BREAKING:** `create_trace_id(seed:)` now raises `ArgumentError` for non-String seeds (previously coerced via `.to_s`). This ensures cross-SDK parity since Python/JS reject non-strings.
- `Langfuse::TraceId.valid?` and `Langfuse::TraceId.to_span_context` are now private (internal API only)

### Removed
- `Langfuse.create_observation_id` and `Langfuse::TraceId.create_observation_id` (no consumer; Python's equivalent is also private)
- `Langfuse::TraceId.valid_observation_id?` (no callers)

### Fixed
- Block exceptions in `observe`/`start_observation` now reliably end the span via `ensure`, even when `span.end` itself raises (#74)
- Reject all-zero trace IDs per W3C trace-context spec (#74)

## [0.6.0] - 2026-03-06

### Added
- Tracing payload masking via `Config#mask` (#68)
- Cost details and usage details support on generations (#61)
- Client-level `environment` and `release` configuration (#52)
- Configurable parameters when creating scores (#48)

### Fixed
- Prompt cache key defaults unlabeled/unversioned fetches to production, matching JS/Python semantics (#63)
- Tags sent as native arrays instead of JSON strings on OTel span attributes (#66)
- Enforce 200-character tag length limit on traces (#67)
- Score API parity between `Langfuse.create_score` and `Client#create_score` (#49)
- Corrected misleading YARD docstrings for SWR cache config

## [0.5.0] - 2026-02-09

### Added
- Trace listing and retrieval endpoints (`list_traces`, `get_trace`) (#47)

### Documentation
- Improved documentation readability and formatting (#46)

## [0.4.0] - 2026-02-08

### Added
- Dataset and dataset item management support (#40)
- Experiment runner for evaluating datasets (#41)
- Project-scoped URL generation for traces, observations, datasets, and experiments (#43)

### Changed
- Extracted duplicated Faraday rescue pattern in API client (#44)

### Documentation
- YARD documentation for all public methods (#42)
- Dataset and experiment usage guides (#45)

## [0.3.0] - 2026-01-23

### Added
- Stale-while-revalidate (SWR) cache strategy for improved performance (#35)

### Fixed
- OpenTelemetry Baggage API method signatures for context propagation (#39)

### Changed
- Relaxed Faraday version constraint for better compatibility with older projects (#37)

## [0.2.0] - 2025-12-19

### Added
- Prompt creation and update methods (`create_prompt`, `update_prompt`) (#36)

## [0.1.0] - 2025-12-01

### Added
- Observe API with context propagation and scoring (#31)
- W3C TraceContext propagator for distributed tracing (#1)
- Ruby 3.4 support (#3)
- OpenTelemetry-based tracing with OTLP export
- Distributed caching with Rails.cache backend and stampede protection
- Prompt management (text and chat) with Mustache templating
- In-memory caching with TTL and bounded expiration-ordered eviction
- Fallback prompt support
- Global configuration pattern with `Langfuse.configure`

### Changed
- Migrated from legacy ingestion API to OTLP endpoint
- Removed `tracing_enabled` configuration flag (#2)

[Unreleased]: https://github.com/simplepractice/langfuse-rb/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/simplepractice/langfuse-rb/releases/tag/v0.1.0
