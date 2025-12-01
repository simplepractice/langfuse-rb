This is the official **Langfuse Ruby SDK** (langfuse-rb), providing LLM tracing, observability, and prompt management capabilities.

**Key Design Principles:**
- **Rails-Friendly**: Global configuration pattern with `Langfuse.configure` block
- **Minimal Dependencies**: Only add dependencies when needed
- **Thread-Safe**: Safe for multi-threaded environments

## Requirements

- **Ruby**: >= 3.2.0 (specified in `.ruby-version` and `langfuse.gemspec`)
- No Rails dependency - works in any Ruby project

## MUST RUN After Making Any Changes

```bash
bundle exec rspec

# coverage should stay over 95%
bundle exec rubocop
```


## API Design Pattern (Critical!)

**✅ CORRECT - Flat API:**
```ruby
client.get_prompt("name")
client.compile_prompt("name", variables: {})
client.create_prompt(...)
```

**❌ INCORRECT - Nested managers:**
```ruby
client.prompt.get("name")          # Don't do this
client.prompt_manager.compile(...) # Don't do this
```

## Global Configuration Pattern
```ruby
# Rails initializer or configuration file
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  config.cache_ttl = 60
end

# Use global singleton client
client = Langfuse.client
prompt = client.get_prompt("greeting")
```

## Ruby Conventions

- **snake_case** for all methods: `get_prompt`, not `getPrompt`
- **Symbol keys** in hashes: `{ role: :user }`, not `{ "role" => "user" }`
- **Keyword arguments**: `get_prompt(name, version: 2)`, not `get_prompt(name, { version: 2 })`
- **Blocks for config**: `configure { |c| ... }`

## Testing Strategy

**Test Types:**
- Unit tests for each class in isolation
- Integration tests for `Client → ApiClient → (mocked HTTP)`
- WebMock for HTTP stubbing
- VCR tests for real API responses (Phase 2+)

**Common Test Pattern:**
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

**Important Testing Notes:**
- WebMock disables external HTTP by default (see `spec_helper.rb`)
- SimpleCov generates coverage report automatically
- Global `Langfuse.reset!` runs before each test
- Use `instance_double` for mocking dependencies

## Code Style

### Naming Conventions
- **Classes**: `PascalCase` (e.g., `TextPromptClient`)
- **Methods**: `snake_case` (e.g., `get_prompt`)
- **Constants**: `SCREAMING_SNAKE_CASE` (e.g., `DEFAULT_TTL`)
- **Instance vars**: `@snake_case` (e.g., `@api_client`)

### Method Length
- Max 22 lines (excluding specs)
- Break longer methods into smaller, testable units

## Important References

- **Langfuse API Docs**: https://langfuse.com/docs/api
- **Langfuse TypeScript SDK**: https://github.com/langfuse/langfuse-js (reference implementation)
