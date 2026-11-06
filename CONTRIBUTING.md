# Contributing

Use Ruby `>= 3.2.0`. After cloning the repository, install dependencies and run the
required checks:

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

`make check` runs both checks. `make help` lists the other development commands.
Run a focused spec with `bundle exec rspec spec/langfuse/client_spec.rb`.
SimpleCov writes `coverage/index.html`; coverage must stay above 95%.

## Code and Tests

Keep the SDK framework-agnostic, preserve the flat client API, and use keyword
arguments and descriptive Ruby names. Follow `.rubocop.yml`: double-quoted strings,
frozen string literals, a 120-character line limit, and methods of at most 22 lines
outside specs. Preserve existing inline comments unless a change makes them invalid.

Document public methods with YARD `@param`, `@return`, and `@raise` tags. Document
private methods only when an invariant or non-obvious decision needs explanation.

Add focused behavioral coverage for new contracts and regressions. Use
`instance_double` for dependencies and WebMock for HTTP integration tests. External
HTTP is disabled by `spec/spec_helper.rb`, which also resets Langfuse between tests.
Do not add live network calls to the ordinary test suite. Application tests that
inspect completed spans can use [Testing Tracing](docs/TESTING.md).

## Verify Against Langfuse

After a change, validate the affected behavior against the Langfuse API with
synthetic data. Set `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, and
`LANGFUSE_BASE_URL` in the test process; the SDK does not load `.env` files.
Follow [Data Access](docs/DATA_ACCESS.md) for SDK and CLI readback. Keep credentials
and private payloads out of logs, commits, and pull requests.

## Issues and Pull Requests

Report bugs with the Ruby and gem versions, a minimal reproduction, expected and
observed behavior, and redacted errors. For features, describe the use case and
required behavior.

Open pull requests against `main` using the repository template. Explain the
behavior change, relevant compatibility limits, and completed verification. Update
the affected guides when the public contract changes. See
[Architecture](docs/ARCHITECTURE.md) for component ownership.

Contributions are licensed under the [MIT License](LICENSE).
