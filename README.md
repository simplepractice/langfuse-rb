![header](https://camo.githubusercontent.com/26d19b945bc752101b4aca468e07b118a44af07340db79af29f7df95505f2cea/68747470733a2f2f6c616e67667573652e636f6d2f6c616e67667573655f6c6f676f5f77686974652e706e67)

# Langfuse Ruby SDK

[![Gem Version](https://badge.fury.io/rb/langfuse.svg)](https://badge.fury.io/rb/langfuse)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2.0-ruby.svg)](https://www.ruby-lang.org/en/)
[![Test Coverage](https://img.shields.io/badge/coverage-99.6%25-brightgreen.svg)](coverage)

> Ruby SDK for [Langfuse](https://langfuse.com) - Open-source LLM observability and prompt management.

## Features

- 🎯 **Prompt Management** - Centralized prompt versioning with Mustache templating
- 📊 **LLM Tracing** - Zero-boilerplate observability built on OpenTelemetry
- ⚡ **Performance** - In-memory or Redis-backed caching with stampede protection
- 💬 **Chat & Text Prompts** - First-class support for both formats
- 🔄 **Automatic Retries** - Built-in exponential backoff for resilient API calls
- 🛡️ **Fallback Support** - Graceful degradation when API unavailable
- 🚀 **Rails-Friendly** - Global configuration pattern, works with any Ruby project

## Installation

```ruby
# Gemfile
gem 'langfuse-rb'
```

```bash
bundle install
```

## Quick Start

**Configure once at startup:**

```ruby
# config/initializers/langfuse.rb (Rails)
# or at the top of your script
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  # Optional: for self-hosted instances
  config.base_url = ENV.fetch('LANGFUSE_BASE_URL', 'https://cloud.langfuse.com')
end
```

**Fetch and use a prompt:**

```ruby
prompt = Langfuse.client.get_prompt("greeting")
message = prompt.compile(name: "Alice")
# => "Hello Alice!"
```

**Trace an LLM call:**

```ruby
Langfuse.observe("chat-completion", as_type: :generation) do |gen|
  response = openai_client.chat(
    parameters: {
      model: "gpt-4",
      messages: [{ role: "user", content: "Hello!" }]
    }
  )

  gen.update(
    model: "gpt-4",
    output: response.dig("choices", 0, "message", "content"),
    usage_details: {
      prompt_tokens: response.dig("usage", "prompt_tokens"),
      completion_tokens: response.dig("usage", "completion_tokens")
    }
  )
end
```

> [!IMPORTANT]  
> For complete reference see [docs](./docs/) section.

## Requirements

- Ruby >= 3.2.0
- No Rails dependency (works with any Ruby project)

## Contributing

We welcome contributions! Please:

1. Check existing [issues](https://github.com/simplepractice/langfuse-rb/issues) and roadmap
2. Open an issue to discuss your idea
3. Fork the repo and create a feature branch
4. Write tests (maintain >95% coverage)
5. Ensure `bundle exec rspec` and `bundle exec rubocop` pass
6. Submit a pull request

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

## Support

- **[GitHub Issues](https://github.com/simplepractice/langfuse-rb/issues)** - Bug reports and feature requests
- **[Langfuse Documentation](https://langfuse.com/docs)** - Platform documentation
- **[API Reference](https://api.reference.langfuse.com)** - REST API reference

## License

[MIT](LICENSE)