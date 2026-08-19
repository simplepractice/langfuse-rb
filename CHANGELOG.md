# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.11.0] - 2026-08-19

> [!NOTE]
> **Contributor acknowledgment:** Thank you to [Alan Marx](https://github.com/Alan-Marx) for contributions in #98, #99, #100, and #102.

### Added
- Read current observations, metrics, and typed scores through the client API (#95).
- Create and read text and correction scores (#97, #102).
- Create scores synchronously and receive the created score ID (#102).
- Check global client readiness locally with `Langfuse.configured?` (#98).
- Send OpenTelemetry batch processor metrics to an application reporter (#99).
- Inject an OpenTelemetry span exporter into the Langfuse tracing pipeline (#100).
- Inspect referenced Mustache variables in source order (#111).
- Disable Langfuse tracing and scoring with one configuration switch (#110).

### Changed
- Export traces through direct Langfuse v4 OTLP ingestion (#103).
- Read timeout, batch, flush interval, and debug defaults from environment variables (#106).
- Bound the asynchronous score queue and split large batch payloads (#109).
- Reject invalid batch settings during client construction (#109).
- Require non-empty API keys and an absolute HTTP or HTTPS base URL (#98).
- Use a null logger when `Config#logger` is `nil` (#98).
- Use a no-op tracer for implicit observations when tracing configuration is invalid (#98).

### Fixed
- Mask third-party OpenTelemetry spans without changing spans for other exporters (#96).
- Reset SDK queues and workers after Ruby `fork` (#107).
- Flush pending spans and scores during normal process exit (#108).
- Apply the configured environment to scores without an explicit override (#105).
- Report invalid numeric, cache, and tracing settings as `ConfigurationError` (#98).
- Validate tracing batch and sampling settings before processor creation (#98).
- Reject explicit Rails cache configuration when `Rails.cache` is unavailable (#98).

### Documentation
- Organize the SDK guides by task and add data-access verification guidance (#113).

## [0.10.1] - 2026-05-05

### Changed
- Refactor prompt cache internals (#91)

## [0.10.0] - 2026-05-05

### Added
- Expose prompt cache operations on the client (#89)

### Changed
- Tighten cache event dispatch and generation safety for prompt caching (#90)

### Documentation
- Align README with sibling Langfuse SDKs (#88)

## [0.9.0] - 2026-04-28

### Added
- Expose `type`, `commit_message`, and `resolution_graph` metadata on text and chat prompt clients (#87)

### Fixed
- Preserve and compile chat prompt message placeholders in parity with Langfuse Python and JS SDKs (#86)
- Preserve raw prompt compile variables instead of HTML-escaping JSON, XML, and HTML-like values (#85)
- Suppress prompt name/version attribution on fallback prompt clients so fallback output is not reported as prompt version 0 (#84)

### Documentation
- Link to upstream Langfuse agent skills and refresh README header image (#81, #83)

## [0.8.0] - 2026-04-24

### Added
- Probabilistic trace sampling with score parity (#60)
- Dataset run lifecycle methods: `get_dataset_run`, `list_dataset_runs`, `delete_dataset_run` (#62)

### Fixed
- Tracing is now isolated-by-default with lazy setup and smart export filtering (#77)

### Documentation
- Align docs with implementation (#78)

## [0.7.0] - 2026-04-14

### Added
- Custom/deterministic trace ID support (#74)

### Fixed
- Bump faraday, json, and addressable to patch CVEs (#75)

### Documentation
- Align docs with implementation (#70, #76)

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

[Unreleased]: https://github.com/simplepractice/langfuse-rb/compare/v0.11.0...HEAD
[0.11.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.10.1...v0.11.0
[0.10.1]: https://github.com/simplepractice/langfuse-rb/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/simplepractice/langfuse-rb/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/simplepractice/langfuse-rb/releases/tag/v0.1.0
