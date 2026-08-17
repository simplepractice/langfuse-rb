# Rails Integration Guide

Read [GETTING_STARTED.md](GETTING_STARTED.md) before you use this guide.
This guide contains Rails integration patterns.

## Initializer Pattern

Keep Langfuse setup in one initializer and keep the ownership boundary explicit.

```ruby
# config/initializers/langfuse.rb
Langfuse.configure do |config|
  config.public_key = Rails.application.credentials.dig(:langfuse, :public_key)
  config.secret_key = Rails.application.credentials.dig(:langfuse, :secret_key)
  config.base_url = ENV.fetch("LANGFUSE_BASE_URL", "https://cloud.langfuse.com")

  config.cache_backend = :rails
  config.cache_ttl = Rails.env.production? ? 300 : 60
  config.cache_stale_ttl = Rails.env.production? ? 300 : 0
  config.logger = Rails.logger
end
```

Notes:

- `Langfuse.configure` stores config only
- module-level tracing works without replacing the global `OpenTelemetry.tracer_provider`
- If you install `Langfuse.tracer_provider` globally, the application controls its lifecycle.
- the SDK flushes pending traces and scores during normal process exit; do not register another `at_exit` hook
- the SDK resets its queues and background workers in forked Puma, Unicorn, or Resque children

## Controller Pattern

Controllers should usually create the root observation, set request-scoped trace attributes, and delegate actual LLM work to a service.

```ruby
class SupportAnswersController < ApplicationController
  def create
    Langfuse.propagate_attributes(
      user_id: current_user.id.to_s,
      session_id: request.request_id
    ) do
      Langfuse.observe("support-answer-request", input: { question: params[:question] }) do |root|
        answer = SupportAnswerService.new.call(
          user: current_user,
          question: params[:question]
        )

        root.event(name: "response-rendered", input: { format: "json" })
        root.update(output: { answered: true })

        render json: { answer: answer }
      end
    end
  end
end
```

The controller owns request context. The service owns prompt selection and model calls.

## Service Object Pattern

This is where most Rails consumers should put Langfuse prompt + generation logic.

```ruby
class SupportAnswerService
  def initialize(llm_client: OpenAI::Client.new(access_token: ENV.fetch("OPENAI_API_KEY")))
    @llm_client = llm_client
  end

  def call(user:, question:)
    Langfuse.observe("support-answer", input: { question: question }) do |root|
      prompt = Langfuse.client.get_prompt("support-answer", label: Rails.env.production? ? "production" : "staging")
      messages = prompt.compile(customer_name: user.name, question: question)

      answer = root.start_observation("openai-chat", as_type: :generation) do |gen|
        gen.model = "gpt-4.1-mini"
        gen.input = messages
        gen.model_parameters = { temperature: 0.2 }

        response = @llm_client.chat(
          parameters: {
            model: "gpt-4.1-mini",
            messages: messages,
            temperature: 0.2
          }
        )

        answer = response.dig("choices", 0, "message", "content")

        gen.update(
          output: answer,
          usage_details: {
            prompt_tokens: response.dig("usage", "prompt_tokens"),
            completion_tokens: response.dig("usage", "completion_tokens"),
            total_tokens: response.dig("usage", "total_tokens")
          }
        )

        answer
      end

      root.update(output: { answer: answer })
      answer
    end
  end
end
```

This keeps the trace shape honest:

- controller/request span at the edge
- workflow root in the service
- generation for the model call itself

## Background Jobs

Rails does not continue Langfuse trace context across job processes automatically. Pass the required context explicitly.

### Enqueue with Explicit Trace Context

```ruby
class DocumentsController < ApplicationController
  def create
    Langfuse.observe("document-upload", input: document_params.to_h) do |root|
      document = Document.create!(document_params)

      ProcessDocumentJob.perform_later(document.id, root.trace_id)
      root.event(name: "job-enqueued", input: { document_id: document.id, queue: "default" })

      render json: document, status: :created
    end
  end
end
```

### Continue the Trace in the Job

```ruby
class ProcessDocumentJob < ApplicationJob
  queue_as :default

  def perform(document_id, trace_id)
    document = Document.find(document_id)

    Langfuse.observe("process-document", { input: { document_id: document_id } }, trace_id: trace_id) do |root|
      text = root.start_observation("extract-text") do |span|
        extracted_text = extract_text(document)
        span.update(output: { characters: extracted_text.length })
        extracted_text
      end

      summary = root.start_observation("summarize", as_type: :generation) do |gen|
        gen.model = "gpt-4.1-mini"
        result = summarize_with_llm(text)
        gen.update(output: result.fetch(:summary), usage_details: result.fetch(:usage))
        result.fetch(:summary)
      end

      root.update(output: { summary: summary })
      document.update!(summary: summary)
    end
  end
end
```

Pass `trace_id` to continue the same trace.
This value does not restore an exact parent span relationship across process boundaries.
For that relationship, pass and restore OpenTelemetry context in the application.

## Testing

For prompt and client unit tests, reset global state between examples and stub
external calls aggressively.

```ruby
RSpec.configure do |config|
  config.before do
    Langfuse.reset!
  end
end
```

Do not combine this reset hook with a process-level injected span exporter.
`Langfuse.reset!` shuts down that exporter. To assert real spans through the normal
Langfuse processor, use the application-owned exporter recipe in
[TESTING.md](TESTING.md).

Stub prompt fetches at the client boundary:

```ruby
RSpec.describe SupportAnswerService do
  let(:prompt) do
    instance_double(
      Langfuse::ChatPromptClient,
      compile: [{ role: "user", content: "How do I reset my password?" }]
    )
  end

  before do
    allow(Langfuse.client).to receive(:get_prompt)
      .with("support-answer", label: "staging")
      .and_return(prompt)
  end
end
```

For SDK integration coverage, prefer the repo's existing WebMock/VCR patterns instead of sprinkling real HTTP into ordinary Rails specs.

## Production Hardening

### Cache Settings

For a multi-process Rails deployment, use `cache_backend = :rails` when Redis supplies `Rails.cache`.

```ruby
Langfuse.configure do |config|
  config.cache_backend = :rails
  config.cache_ttl = 300
  config.cache_stale_ttl = 300
end
```

### Prompt Fallbacks

Use fallbacks for prompts that must not take the request path down:

```ruby
prompt = Langfuse.client.get_prompt(
  "support-answer",
  label: "production",
  fallback: [
    { role: "system", content: "You are a helpful assistant." },
    { role: "user", content: "{{question}}" }
  ],
  type: :chat
)
```

### Global OTel Install

If you install `Langfuse.tracer_provider` as the global provider, apply this lifecycle contract:

- `Langfuse.reset!` tears down the internal provider
- `Langfuse.shutdown` shuts it down
- After either call, install the provider again if the application still requires it globally.

## Operational Debugging

Set the log level to `DEBUG` to examine configuration and export behavior:

```ruby
Langfuse.configure do |config|
  config.logger = Rails.logger
  config.logger.level = Logger::DEBUG
end
```

Useful console checks:

```ruby
Langfuse.configuration
Langfuse.client.prompt_cache_stats
```

## Troubleshooting

### Prompts Not Updating

The usual problem is stale cache, not a broken prompt API.

1. Wait for `cache_ttl` to expire.
2. Refresh the specific prompt when the application needs the current state.
3. Invalidate the prompt name or clear the prompt cache namespace.
4. Lower `cache_ttl` in development when you test prompt changes.

```ruby
Langfuse.client.refresh_prompt("greeting", label: "production")
Langfuse.client.invalidate_prompt_cache_by_name("greeting")
Langfuse.client.clear_prompt_cache
```

### Traces Missing Entirely

Check the boring stuff first:

```ruby
Langfuse.configuration.public_key.present?
Langfuse.configuration.secret_key.present?
Langfuse.configuration.base_url.present?
```

Then check the ownership assumption:

- `Langfuse.observe(...)` should work once Langfuse is configured
- The SDK does not export third-party ambient OpenTelemetry spans unless you install `Langfuse.tracer_provider`.
- `should_export_span` only runs for spans handled by Langfuse's provider

### Unexpected Spans After Global Install

This result occurs when the application installs the Langfuse provider globally.
In this mode, Langfuse receives application-wide spans.
Use `should_export_span` to reduce this export set.
The isolated default mode does not export these spans.
