# AGENTS

This repository is the official `langfuse-rb` SDK for LLM tracing, observability, and prompt management.

## 1. Non-Negotiables

- Ruby version must stay `>= 3.2.0` (see `.ruby-version` and `langfuse.gemspec`).
- Keep the SDK framework-agnostic (no Rails dependency).
- Do not delete existing inline comments unless code changes make them invalid.
- After any change, validate output/expectations against the Langfuse API using the installed `langfuse` Codex skill.
- After any change, run:

```bash
bundle exec rspec
# coverage should stay over 95%
bundle exec rubocop
```

## 2. Core Design Constraints

- Rails-friendly global configuration via `Langfuse.configure`.
- Minimal dependencies: only add new gems when justified.
- Thread-safe behavior across SDK components.
- Prefer the global singleton client pattern when demonstrating usage.

```ruby
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  config.cache_ttl = 60
end

client = Langfuse.client
prompt = client.get_prompt("greeting")
```

## 3. Public API Shape (Critical)

Use a flat client API. Do not introduce nested managers.

```ruby
# Correct
client.get_prompt("name")
client.compile_prompt("name", variables: {})
client.create_prompt(...)
```

```ruby
# Incorrect
client.prompt.get("name")
client.prompt_manager.compile(...)
```

## 4. Ruby Conventions

- Methods: `snake_case` (`get_prompt`, not `getPrompt`)
- Classes: `PascalCase` (`TextPromptClient`)
- Constants: `SCREAMING_SNAKE_CASE` (`DEFAULT_TTL`)
- Instance variables: `@snake_case` (`@api_client`)
- Hash keys: symbols (`{ role: :user }`, not `{ "role" => "user" }`)
- Prefer keyword arguments (`get_prompt(name, version: 2)`)
- Use blocks for config (`configure { |c| ... }`)

## 5. Documentation Rules

- Every public method must include YARD docs with `@param`, `@return`, and `@raise`.
- Private methods should only be documented when the why is non-obvious (invariants, surprising behavior, non-trivial logic), using `@api private`.
- For obvious private method types, skip verbose param/return docs.

## 6. Method Size Guidance

- Keep methods at 22 lines max (excluding specs).
- Split long methods into smaller testable units.

## 7. Testing Expectations

- Unit tests for classes in isolation.
- Integration tests across `Client -> ApiClient -> mocked HTTP`.
- WebMock for HTTP stubs.
- VCR for real API responses (Phase 2+).

Testing notes:
- External HTTP is disabled by default (see `spec_helper.rb`).
- SimpleCov runs automatically.
- `Langfuse.reset!` runs before each test.
- Use `instance_double` for dependencies.

Example structure:

```ruby
RSpec.describe Langfuse::SomeClass do
  describe "#some_method" do
    context "when condition is met" do
      it "does the expected thing" do
        # Arrange, Act, Assert
      end
    end
  end
end
```

## 8. References

- Langfuse API docs: https://langfuse.com/docs/api
- Langfuse TypeScript SDK reference: https://github.com/langfuse/langfuse-js
