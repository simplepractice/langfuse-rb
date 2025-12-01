# Prompt Management Guide

Complete guide to managing LLM prompts with Langfuse.

## Overview

Langfuse centralizes prompt management, allowing you to:
- Version and iterate prompts without code changes
- A/B test prompt variations
- Roll back to previous versions
- Manage prompts across environments (dev/staging/prod)

The SDK supports two prompt types:
- **Text Prompts:** Single string templates (e.g., instructions, system messages)
- **Chat Prompts:** Structured message arrays (e.g., conversation templates)

## Text Prompts

### Fetching Text Prompts

```ruby
client = Langfuse.client
prompt = client.get_prompt("product-description")
# => Returns TextPromptClient instance
```

The returned `TextPromptClient` provides:

```ruby
prompt.name       # => "product-description"
prompt.version    # => 3
prompt.labels     # => ["production"]
prompt.tags       # => ["marketing", "seo"]
prompt.config     # => { "temperature" => 0.7, "model" => "gpt-4" }
prompt.prompt     # => "Write a {{tone}} product description for {{product_name}}..."
```

### Compiling Text Prompts

Use `compile` with variables:

```ruby
prompt = client.get_prompt("product-description")

description = prompt.compile(
  tone: "professional",
  product_name: "Wireless Headphones",
  features: "noise-cancelling, 40-hour battery"
)

puts description
# => "Write a professional product description for Wireless Headphones..."
```

### Using Metadata

The `config` hash stores prompt-specific settings:

```ruby
prompt = client.get_prompt("chat-completion")

# Use config for LLM parameters
openai_client.chat(
  parameters: {
    model: prompt.config["model"],              # => "gpt-4"
    temperature: prompt.config["temperature"],  # => 0.7
    messages: [{ role: "user", content: prompt.compile(input: user_input) }]
  }
)
```

## Chat Prompts

### Fetching Chat Prompts

```ruby
prompt = client.get_prompt("customer-support")
# => Returns ChatPromptClient instance
```

The returned `ChatPromptClient` has the same properties as `TextPromptClient`, but `compile` returns an array of message hashes.

### Compiling Chat Prompts

Chat prompts compile to an array of messages:

```ruby
prompt = client.get_prompt("customer-support")

messages = prompt.compile(
  customer_name: "Alice",
  product: "Premium Plan",
  issue_type: "billing"
)

puts messages
# => [
#   { role: :system, content: "You are a helpful customer support agent..." },
#   { role: :user, content: "Customer Alice has a billing issue with Premium Plan" }
# ]
```

**Note:** Message roles are returned as symbols (`:system`, `:user`, `:assistant`), matching Ruby conventions.

### Using with LLM Libraries

Direct integration with OpenAI:

```ruby
require 'openai'

client = OpenAI::Client.new
prompt = Langfuse.client.get_prompt("chat-assistant")

messages = prompt.compile(
  user_name: "Bob",
  context: "Product recommendations"
)

response = client.chat(
  parameters: {
    model: prompt.config["model"],
    temperature: prompt.config["temperature"],
    messages: messages.map { |m| { role: m[:role].to_s, content: m[:content] } }
  }
)
```

## Versioning

### Fetching Specific Versions

Fetch by version number:

```ruby
prompt = client.get_prompt("greeting", version: 2)
puts prompt.version  # => 2
```

Fetch by label:

```ruby
prompt = client.get_prompt("greeting", label: "production")
puts prompt.labels  # => ["production"]
puts prompt.version  # => whichever version has "production" label
```

### Versioning Strategy

**Version numbers** are immutable and sequential:

```ruby
# Version 1 (initial)
"Hello {{name}}!"

# Version 2 (improved)
"Hello {{name}}, welcome back!"

# Version 3 (A/B test variant)
"Hi {{name}}, great to see you!"
```

**Labels** are mutable pointers:

```ruby
# Production points to version 2
prompt = client.get_prompt("greeting", label: "production")  # => version 2

# After promoting version 3 in Langfuse UI:
prompt = client.get_prompt("greeting", label: "production")  # => version 3
```

### Best Practices

1. **Default to latest:** Omit `version`/`label` in development to always get the newest version
2. **Use labels in production:** Pin to `production` label for stability
3. **Version for rollback:** Keep version numbers for emergency rollbacks

```ruby
# Development
prompt = client.get_prompt("greeting")  # Latest version

# Production
prompt = client.get_prompt("greeting", label: "production")  # Stable

# Rollback scenario
prompt = client.get_prompt("greeting", version: 2)  # Explicit old version
```

## Mustache Templating

Langfuse uses [Mustache](https://mustache.github.io/) for variable interpolation.

### Basic Variables

```ruby
# Template: "Hello {{name}}!"
prompt.compile(name: "Alice")
# => "Hello Alice!"
```

### Nested Objects

```ruby
# Template: "{{user.name}} lives in {{user.city}}"
prompt.compile(user: { name: "Bob", city: "NYC" })
# => "Bob lives in NYC"
```

### Arrays

```ruby
# Template: "{{#items}}• {{name}}\n{{/items}}"
prompt.compile(items: [{ name: "Item 1" }, { name: "Item 2" }])
# => "• Item 1\n• Item 2\n"
```

### Conditionals

```ruby
# Template: "{{#premium}}Premium features enabled{{/premium}}"
prompt.compile(premium: true)
# => "Premium features enabled"

prompt.compile(premium: false)
# => ""
```

### HTML Escaping

Mustache escapes HTML by default. Use triple braces for raw output:

```ruby
# Template: "{{safe}} vs {{{unsafe}}}"
prompt.compile(safe: "<b>Bold</b>", unsafe: "<b>Bold</b>")
# => "&lt;b&gt;Bold&lt;/b&gt; vs <b>Bold</b>"
```

### Complex Example

Template in Langfuse UI:

```mustache
You are a {{role}} helping with {{task}}.

User profile:
- Name: {{user.name}}
- Tier: {{user.tier}}
{{#user.preferences}}
- Preference: {{.}}
{{/user.preferences}}

{{#context}}
Context: {{context}}
{{/context}}
```

Compilation:

```ruby
prompt.compile(
  role: "sales assistant",
  task: "product recommendations",
  user: {
    name: "Alice",
    tier: "Premium",
    preferences: ["eco-friendly", "fast shipping"]
  },
  context: "Customer browsing electronics"
)

# Output:
# You are a sales assistant helping with product recommendations.
#
# User profile:
# - Name: Alice
# - Tier: Premium
# - Preference: eco-friendly
# - Preference: fast shipping
#
# Context: Customer browsing electronics
```

## Convenience Methods

### `compile_prompt` - Fetch and Compile

Combine fetching and compilation in one call:

```ruby
# Instead of:
prompt = client.get_prompt("greeting")
message = prompt.compile(name: "Alice")

# Use:
message = client.compile_prompt("greeting", variables: { name: "Alice" })
```

With versioning:

```ruby
message = client.compile_prompt(
  "greeting",
  variables: { name: "Alice" },
  label: "production"
)
```

### `list_prompts` - Browse Available Prompts

List all prompts in your project:

```ruby
prompts = client.list_prompts
prompts.each do |p|
  puts "#{p['name']} (v#{p['version']})"
end
```

With pagination:

```ruby
prompts = client.list_prompts(page: 2, limit: 50)
```

## Fallback Handling

Provide a fallback template for development or when prompts don't exist:

```ruby
prompt = client.get_prompt(
  "new-feature-prompt",
  fallback: "Hello {{name}}!",
  type: :text
)

message = prompt.compile(name: "Bob")
# If prompt doesn't exist in Langfuse, uses fallback
```

**Important:** You must specify `type:` when using `fallback`.

### Fallback Best Practices

```ruby
# Good: Development with fallback
if Rails.env.development?
  prompt = client.get_prompt("beta-feature",
    fallback: "Default behavior for {{input}}",
    type: :text
  )
else
  prompt = client.get_prompt("beta-feature")  # Fail loudly in production
end
```

```ruby
# Good: Graceful degradation
begin
  prompt = client.get_prompt("personalized-greeting")
  message = prompt.compile(name: user.name, tier: user.tier)
rescue Langfuse::NotFoundError
  message = "Hello #{user.name}!"  # Simple fallback
end
```

See [ERROR_HANDLING.md](ERROR_HANDLING.md) for exception handling strategies.

## Caching

Prompts are cached automatically. Default TTL is 60 seconds.

```ruby
# First call: Fetches from API
prompt1 = client.get_prompt("greeting")  # HTTP request

# Within TTL: Returns from cache
prompt2 = client.get_prompt("greeting")  # No HTTP request
```

Configure cache TTL:

```ruby
Langfuse.configure do |config|
  config.cache_ttl = 300  # 5 minutes
end
```

See [CACHING.md](CACHING.md) for advanced caching strategies (warming, stampede protection).

## Combining Prompts with Tracing

Track prompt usage in traces:

```ruby
Langfuse.observe("generate-response", as_type: :generation) do |gen|
  prompt = Langfuse.client.get_prompt("chat-assistant", label: "production")

  messages = prompt.compile(
    user_query: user_input,
    context: relevant_docs
  )

  response = openai_client.chat(
    parameters: {
      model: prompt.config["model"],
      messages: messages
    }
  )

  # Record prompt metadata in trace
  gen.model = prompt.config["model"]
  gen.input = messages
  gen.output = response.dig("choices", 0, "message", "content")
  gen.usage = {
    prompt_tokens: response.dig("usage", "prompt_tokens"),
    completion_tokens: response.dig("usage", "completion_tokens"),
    total_tokens: response.dig("usage", "total_tokens")
  }
  gen.metadata = {
    prompt_name: prompt.name,
    prompt_version: prompt.version,
    prompt_labels: prompt.labels
  }

  response
end
```

This creates a trace with full prompt provenance, making it easy to correlate outputs with specific prompt versions.

See [TRACING.md](TRACING.md) for more tracing patterns.

## See Also

- [GETTING_STARTED.md](GETTING_STARTED.md) - Basic prompt usage
- [TRACING.md](TRACING.md) - Tracking prompt usage in traces
- [CACHING.md](CACHING.md) - Optimizing prompt fetch performance
- [ERROR_HANDLING.md](ERROR_HANDLING.md) - Handling prompt errors
- [API_REFERENCE.md](API_REFERENCE.md) - Complete method signatures
