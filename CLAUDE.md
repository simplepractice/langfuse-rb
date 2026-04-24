Langfuse Ruby SDK — LLM tracing, observability, and prompt management.

Ruby >= 3.2.0. No Rails dependency.

## Verify After Every Change

```bash
bundle exec rspec          # coverage must stay > 95%
bundle exec rubocop
```

- After any change, validate output/expectations against the Langfuse API using the `langfuse` skill (`.claude/skills/langfuse/`).
- Every PR must include a verification script in `scratchpad/` that exercises the change against the real Langfuse API (via the `langfuse` skill / CLI). Mocks and unit tests don't catch API-shape regressions — the scratchpad script does. `scratchpad/` is untracked, so the script lives alongside the PR but is not committed.

## Hard Constraints

- **Flat API only.** All methods live directly on `Client`. Never nest behind sub-objects like `client.prompt.get(...)` or `client.prompt_manager.compile(...)`.
- **Thread-safe.** All shared state must be safe for concurrent access.
- **Minimal dependencies.** Don't add gems unless truly necessary.
- **Max 22 lines per method** (excluding specs). Extract when exceeded.
- **Do not delete existing inline comments** unless the associated code changes in a way that invalidates them.

## API Shape

```ruby
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  config.cache_ttl = 60
end

client = Langfuse.client
client.get_prompt("name")
client.compile_prompt("name", variables: {})
client.create_prompt(...)
```

## Style

- Keyword arguments over option hashes: `get_prompt(name, version: 2)`
- Symbol keys: `{ role: :user }`, not `{ "role" => "user" }`
- Blocks for configuration: `configure { |c| ... }`
- YARD docs (`@param`, `@return`, `@raise`) on every public method
- Private methods: document only non-obvious "why". Use `@api private` tag. Skip `@param`/`@return` when types are obvious from naming.

## Testing

- WebMock disables external HTTP by default (`spec_helper.rb`)
- `Langfuse.reset!` runs before each test
- Use `instance_double` for mocking
- SimpleCov runs automatically

## References

- API docs: https://langfuse.com/docs/api
- TypeScript SDK (reference impl): https://github.com/langfuse/langfuse-js
