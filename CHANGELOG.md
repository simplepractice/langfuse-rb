# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Create and update methods for prompts (#36)

## [0.1.0] - 2025-12-01

### Added
- Observe API with context propagation and scoring (#31)
- W3C TraceContext propagator for distributed tracing (#1)
- Ruby 3.4 support (#3)
- OpenTelemetry-based tracing with OTLP export
- Distributed caching with Rails.cache backend and stampede protection
- Prompt management (text and chat) with Mustache templating
- In-memory caching with TTL and LRU eviction
- Fallback prompt support
- Global configuration pattern with `Langfuse.configure`

### Changed
- Migrated from legacy ingestion API to OTLP endpoint
- Removed `tracing_enabled` configuration flag (#2)

[Unreleased]: https://github.com/simplepractice/langfuse-rb/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/simplepractice/langfuse-rb/releases/tag/v0.1.0
