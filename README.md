![header](https://camo.githubusercontent.com/26d19b945bc752101b4aca468e07b118a44af07340db79af29f7df95505f2cea/68747470733a2f2f6c616e67667573652e636f6d2f6c616e67667573655f6c6f676f5f77686974652e706e67)

# Langfuse Ruby SDK

[![Gem Version](https://badge.fury.io/rb/langfuse-rb.svg?icon=si%3Arubygems)](https://badge.fury.io/rb/langfuse-rb)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2.0-ruby.svg)](https://www.ruby-lang.org/en/)
[![Test Coverage](https://img.shields.io/badge/coverage-99.6%25-brightgreen.svg)](coverage)

> Ruby SDK for [Langfuse](https://langfuse.com) - Open-source LLM observability and prompt management.

## Installation

```ruby
gem "langfuse-rb"
```

## Quick Start

```ruby
Langfuse.configure do |config|
  config.public_key = ENV["LANGFUSE_PUBLIC_KEY"]
  config.secret_key = ENV["LANGFUSE_SECRET_KEY"]
  config.base_url = ENV.fetch("LANGFUSE_BASE_URL", "https://cloud.langfuse.com")

  # Optional: sample traces and trace-linked scores deterministically
  config.sample_rate = 1.0
end

message = Langfuse.client.compile_prompt(
  "greeting",
  variables: { name: "Alice" }
)
```

Langfuse tracing is isolated by default. `Langfuse.configure` stores configuration only; it does not replace `OpenTelemetry.tracer_provider`.

`sample_rate` is applied to traces and trace-linked scores. Rebuild the client with `Langfuse.reset!` before expecting runtime sampling changes to take effect.

## Trace an LLM Call

```ruby
Langfuse.observe("chat-completion", as_type: :generation) do |gen|
  gen.model = "gpt-4.1-mini"
  gen.input = [{ role: "user", content: "Hello!" }]

  response = openai_client.chat(
    parameters: {
      model: "gpt-4.1-mini",
      messages: [{ role: "user", content: "Hello!" }]
    }
  )

  gen.update(
    output: response.dig("choices", 0, "message", "content"),
    usage_details: {
      prompt_tokens: response.dig("usage", "prompt_tokens"),
      completion_tokens: response.dig("usage", "completion_tokens")
    }
  )
end
```

## Start Here

- [Documentation Hub](docs/README.md)
- [Getting Started](docs/GETTING_STARTED.md)
- [Prompts](docs/PROMPTS.md)
- [Tracing](docs/TRACING.md)
- [Scoring](docs/SCORING.md)
- [Rails Patterns](docs/RAILS.md)
- [Agent Skills](https://github.com/langfuse/skills)
- [Agent Skill Docs](https://langfuse.com/docs/api-and-data-platform/features/agent-skill)

## License

[MIT](LICENSE)
