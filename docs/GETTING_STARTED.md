# Getting Started with Langfuse Ruby SDK

This guide walks you through installing and using the Langfuse Ruby SDK from scratch.

## Prerequisites

- Ruby >= 3.2.0
- A Langfuse account (sign up at [langfuse.com](https://langfuse.com))
- Your Langfuse API keys (found in your project settings)

## Installation

Add the gem to your Gemfile:

```ruby
gem 'langfuse-rb'
```

Then run:

```bash
bundle install
```

Or install directly:

```bash
gem install langfuse-rb
```

## Configuration

The SDK uses a global configuration pattern. Set up once at application startup.

### Plain Ruby

```ruby
require 'langfuse-rb'

Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  config.base_url = "https://cloud.langfuse.com"  # Optional, this is default
end
```

### Rails

Create `config/initializers/langfuse.rb`:

```ruby
Langfuse.configure do |config|
  config.public_key = Rails.application.credentials.dig(:langfuse, :public_key)
  config.secret_key = Rails.application.credentials.dig(:langfuse, :secret_key)

  # Optional: Rails-specific settings
  config.cache_backend = :rails  # Use Rails.cache (requires Redis)
  # Logger auto-detected as Rails.logger
end
```

**Environment Variables:**

Set these in your shell or `.env` file:

```bash
export LANGFUSE_PUBLIC_KEY="pk-lf-..."
export LANGFUSE_SECRET_KEY="sk-lf-..."
```

**Tip:** If you're contributing to the SDK, use `make env` to quickly set up a `.env` file from the template.

For all configuration options, see [CONFIGURATION.md](CONFIGURATION.md).

## Your First Prompt

Langfuse manages your LLM prompts centrally. Let's fetch and use one.

### 1. Create a Prompt in Langfuse UI

Go to your Langfuse dashboard → Prompts → Create new prompt:

- **Name:** `greeting`
- **Type:** Text
- **Template:** `Hello {{name}}! Welcome to {{app_name}}.`

### 2. Fetch and Compile

**Plain Ruby:**

```ruby
require 'langfuse-rb'

client = Langfuse.client
prompt = client.get_prompt("greeting")

# Compile with variables
message = prompt.compile(name: "Alice", app_name: "MyApp")
puts message
# => "Hello Alice! Welcome to MyApp."
```

**Rails Controller:**

```ruby
class GreetingsController < ApplicationController
  def show
    client = Langfuse.client
    prompt = client.get_prompt("greeting")

    @message = prompt.compile(
      name: current_user.name,
      app_name: "MyApp"
    )

    render json: { message: @message }
  end
end
```

### Convenience Method

Fetch and compile in one call:

```ruby
message = Langfuse.client.compile_prompt(
  "greeting",
  variables: { name: "Alice", app_name: "MyApp" }
)
```

See [PROMPTS.md](PROMPTS.md) for advanced prompt management (chat prompts, versioning, fallbacks).

## Your First Trace

Instrument any operation with `Langfuse.observe`:

### Basic Tracing

**Plain Ruby:**

```ruby
require 'langfuse-rb'

result = Langfuse.observe("generate-greeting", input: { name: "Alice" }) do |obs|
  # Your code here
  message = "Hello Alice!"

  obs.update(output: { message: message })
  message  # Return value
end

puts result  # => "Hello Alice!"
```

**Rails Service Object:**

```ruby
class GreetingService
  def call(user)
    Langfuse.observe("greeting-service", input: { user_id: user.id }) do |obs|
      prompt = Langfuse.client.get_prompt("greeting")
      message = prompt.compile(name: user.name, app_name: "MyApp")

      obs.update(output: { message: message }, metadata: { user_id: user.id })
      message
    end
  end
end
```

### Tracing LLM Calls

Use the `:generation` observation type for LLM calls:

**Plain Ruby with OpenAI:**

```ruby
require 'openai'
require 'langfuse-rb'

client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])

response = Langfuse.observe("openai-chat", { model: "gpt-4" }, as_type: :generation) do |gen|
  result = client.chat(
    parameters: {
      model: "gpt-4",
      messages: [{ role: "user", content: "Say hello!" }],
      temperature: 0.7
    }
  )

  gen.model = "gpt-4"
  gen.model_parameters = { temperature: 0.7 }
  gen.usage = {
    prompt_tokens: result.dig("usage", "prompt_tokens"),
    completion_tokens: result.dig("usage", "completion_tokens"),
    total_tokens: result.dig("usage", "total_tokens")
  }
  gen.output = result.dig("choices", 0, "message", "content")

  result
end
```

**Rails Background Job:**

```ruby
class AiSummaryJob < ApplicationJob
  queue_as :default

  def perform(article_id)
    Langfuse.observe("summarize-article", { article_id: article_id }, as_type: :generation) do |gen|
      article = Article.find(article_id)

      response = openai_client.chat(
        parameters: {
          model: "gpt-4",
          messages: [{ role: "user", content: "Summarize: #{article.body}" }]
        }
      )

      summary = response.dig("choices", 0, "message", "content")

      gen.model = "gpt-4"
      gen.input = { article_body: article.body[0..100] }
      gen.output = { summary: summary }
      gen.usage = {
        prompt_tokens: response.dig("usage", "prompt_tokens"),
        completion_tokens: response.dig("usage", "completion_tokens"),
        total_tokens: response.dig("usage", "total_tokens")
      }

      article.update!(ai_summary: summary)
    end
  end
end
```

See [TRACING.md](TRACING.md) for advanced patterns (nested spans, RAG, multi-turn conversations).

## Verify It's Working

After running traced code, check your Langfuse dashboard:

1. Go to **Traces** tab
2. Find your trace by name (e.g., "generate-greeting")
3. Click to see detailed timeline, inputs/outputs, and metadata

You can also get the trace URL programmatically:

```ruby
Langfuse.observe("my-operation") do |obs|
  puts obs.trace_url
  # => "https://cloud.langfuse.com/traces/abc123..."
end
```

## Troubleshooting

### Authentication Errors

```ruby
# Error: Langfuse::UnauthorizedError
# Solution: Check your API keys
```

Verify keys are correct:

```ruby
Langfuse.configure do |config|
  puts "Public key: #{config.public_key}"  # Should start with "pk-lf-"
  puts "Secret key: #{config.secret_key[0..8]}..."  # Should start with "sk-lf-"
end
```

### Prompts Not Found

```ruby
# Error: Langfuse::NotFoundError: Prompt 'greeting' not found
# Solution: Ensure prompt exists in Langfuse UI and is deployed
```

Use fallback for development:

```ruby
prompt = client.get_prompt("greeting",
  fallback: "Hello {{name}}!",
  type: :text
)
```

### Connection Timeouts

```ruby
# Increase timeout in config
Langfuse.configure do |config|
  config.timeout = 10  # Default is 5 seconds
end
```

See [ERROR_HANDLING.md](ERROR_HANDLING.md) for complete error reference.

## Next Steps

- **[PROMPTS.md](PROMPTS.md)** - Chat prompts, versioning, Mustache templating
- **[TRACING.md](TRACING.md)** - Nested observations, RAG patterns, OpenTelemetry
- **[SCORING.md](SCORING.md)** - Add quality scores to traces
- **[CACHING.md](CACHING.md)** - Optimize performance with caching
- **[RAILS.md](RAILS.md)** - Rails-specific patterns and testing
- **[CONFIGURATION.md](CONFIGURATION.md)** - All configuration options
- **[API_REFERENCE.md](API_REFERENCE.md)** - Complete method reference
