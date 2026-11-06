# Rails Integration

## Configuration

Configure before application code first uses Langfuse:

```ruby
# config/initializers/langfuse.rb
Langfuse.configure do |config|
  config.environment = Rails.env.to_s
  config.logger = Rails.logger
  config.cache_backend = :rails
  config.cache_ttl = 60
  config.cache_stale_ttl = 300
end
```

Credentials and host come from the environment. If using Rails credentials instead,
assign `public_key` and `secret_key` explicitly. The Rails backend requires
`Rails.cache`; sharing across processes depends on its store. See [Caching](CACHING.md).

Tracing uses an isolated provider by default. Normal exit attempts a flush, and the
SDK resets its queues and workers after Ruby `fork`. No additional `at_exit` hook
is needed. See [Configuration](CONFIGURATION.md) for lifecycle limits.

## Request Context

Create an observation around the workflow and propagate request attributes before
starting children:

```ruby
class SupportAnswersController < ApplicationController
  def create
    Langfuse.propagate_attributes(user_id: current_user.id.to_s, session_id: request.request_id) do
      Langfuse.observe("support-answer", input: { question: params[:question] }) do |root|
        answer = SupportAnswerService.call(params[:question])
        root.update(output: answer)
        render json: { answer: answer }
      end
    end
  end
end
```

The service can create nested generations as shown in [Tracing](TRACING.md).
The SDK does not instrument Rails controllers or model calls automatically.

## Background Jobs

ActiveJob and Sidekiq do not carry Langfuse context across processes automatically.
Pass the required IDs explicitly:

```ruby
Langfuse.observe("document-upload") do |root|
  ProcessDocumentJob.perform_later(document.id, root.trace_id)
end

class ProcessDocumentJob < ApplicationJob
  def perform(document_id, trace_id)
    Langfuse.observe("process-document", trace_id: trace_id, input: { document_id: document_id }) do |root|
      summary = DocumentSummaryService.call(document_id)
      root.update(output: summary)
    end
  end
end
```

A trace ID joins the same trace but creates a separate root; it does not restore the
parent observation, user, or session. Pass those attributes separately when needed.
For an exact parent-child relationship, configure OpenTelemetry context injection
and extraction in the application. For independent jobs, use separate traces with
a shared `session_id`.

## Tests and Diagnostics

Stub prompt fetches at the client boundary with `instance_double`. For real span
assertions without network access, use [Testing Tracing](TESTING.md).
`Langfuse.reset!` shuts down the configured exporter, so do not combine per-test
resets with a shared exporter instance.

For stale prompts, use `refresh_prompt` or the cache invalidation methods. For
missing traces, check telemetry switches, sampling, and provider ownership. See
[Error Handling](ERROR_HANDLING.md); do not print the configuration object because
it contains credentials.
