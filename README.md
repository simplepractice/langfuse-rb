![Langfuse Ruby SDK Banner](https://github.com/user-attachments/assets/59422d0a-6ecb-4e5f-a21c-cae955b5ce75)

# Langfuse Ruby SDK

[![MIT License](https://img.shields.io/badge/License-MIT-red.svg?style=flat-square)](https://opensource.org/licenses/MIT)
[![Gem Version](https://badge.fury.io/rb/langfuse-rb.svg?icon=si%3Arubygems)](https://badge.fury.io/rb/langfuse-rb)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2.0-ruby.svg)](https://www.ruby-lang.org/en/)
[![Test Coverage](https://img.shields.io/badge/coverage-99.6%25-brightgreen.svg)](coverage)
[![GitHub Repo stars](https://img.shields.io/github/stars/langfuse/langfuse?style=flat-square&logo=GitHub&label=langfuse%2Flangfuse)](https://github.com/langfuse/langfuse)
[![Discord](https://img.shields.io/discord/1111061815649124414?style=flat-square&logo=Discord&logoColor=white&label=Discord&color=%23434EE4)](https://discord.gg/7NXusRtqYU)
[![YC W23](https://img.shields.io/badge/Y%20Combinator-W23-orange?style=flat-square)](https://www.ycombinator.com/companies/langfuse)

Ruby SDK for [Langfuse](https://langfuse.com) - open-source LLM tracing, observability, scoring, datasets, experiments, and prompt management.

## Installation

```ruby
gem "langfuse-rb"
```

Then install:

```bash
bundle install
```

## Quick Start

```ruby
require "langfuse"

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

For short-lived scripts and jobs, call `Langfuse.shutdown` before exit so queued traces and scores are flushed.

## Features

| Capability | Ruby API | Docs |
| --- | --- | --- |
| Prompt management | `get_prompt`, `compile_prompt`, `create_prompt`, `update_prompt`, `list_prompts` | [Prompts](docs/PROMPTS.md) |
| Tracing | `Langfuse.observe`, `Langfuse.propagate_attributes`, `Langfuse.tracer_provider` | [Tracing](docs/TRACING.md) |
| Scores and feedback | `create_score`, `flush_scores` | [Scoring](docs/SCORING.md) |
| Datasets and experiments | `create_dataset`, `run_experiment` | [Datasets](docs/DATASETS.md), [Experiments](docs/EXPERIMENTS.md) |
| Rails integration patterns | Rails cache, initializers, jobs, service objects | [Rails Patterns](docs/RAILS.md) |

## Documentation

- [Documentation Hub](docs/README.md) - start here for consumer docs
- [Getting Started](docs/GETTING_STARTED.md) - first prompt, first trace, first verification
- [API Reference](docs/API_REFERENCE.md) - public Ruby signatures
- [Configuration](docs/CONFIGURATION.md) - credentials, caching, tracing ownership, and sampling
- [Langfuse Docs](https://langfuse.com/docs) - platform docs and concepts
- [Agent Skills](https://github.com/langfuse/skills) - agent-ready Langfuse workflows
- [Agent Skill Docs](https://langfuse.com/docs/api-and-data-platform/features/agent-skill)

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

[MIT](LICENSE)
