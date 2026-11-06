# Error Handling

## Exceptions

| Exception | Meaning |
| --- | --- |
| `Langfuse::ConfigurationError` | Invalid local configuration. |
| `Langfuse::UnauthorizedError` | HTTP 401; verify the credential pair and host. |
| `Langfuse::NotFoundError` | Requested resource, prompt version, or label was not found. |
| `Langfuse::ApiError` | API, transport, or synchronous score-acceptance failure. Parent of `UnauthorizedError` and `NotFoundError`. |
| `Langfuse::CacheWarmingError` | One or more fetches failed during `CacheWarmer#warm!`. |
| `ArgumentError` | Invalid method arguments, chat placeholder values, or score values; missing active context for score helpers. |
| `Mustache::Parser::SyntaxError` | Invalid template syntax during variable inspection or rendering. |

SDK-defined errors inherit from `Langfuse::Error`. Ruby argument errors do not.
Catch the error that your application can recover from rather than suppressing all
exceptions.

## Prompt Fallbacks

```ruby
prompt = Langfuse.client.get_prompt(
  "greeting",
  label: "production",
  fallback: "Hello {{name}}!",
  type: :text
)
message = prompt.compile(name: "Ada")
```

A fallback requires `type: :text` or `:chat`. It catches API errors, including
not-found and authentication failures, but not invalid local configuration or
compilation errors. Fallback content is not cached. `prompt.is_fallback` reports
whether it was used. See [Prompt Management](PROMPTS.md).

## Delivery and Retries

Score requests retry connection failures, timeouts, HTTP 429, and HTTP 5xx responses
up to twice with exponential backoff. Automatic retries reuse the score ID and
timestamp. Asynchronous failures follow the retention and rejection rules in
[Scoring](SCORING.md#batching-behavior); `create_score!` raises if acceptance fails.
For a retry across separate calls, reuse the same `id`, `timestamp`, and score data.

Other API requests retry connection failures and timeouts up to twice. Do not rely
on automatic HTTP-status retries outside the score transport. Prompt creation can
create another version when repeated, so retry it only when duplicate creation is
acceptable or the previous outcome is known.

Tracing and asynchronous score export log delivery failures. A successful flush
call does not prove backend persistence. Normal exit attempts a flush but cannot
guarantee delivery during an outage. Use [bounded readback](DATA_ACCESS.md) when
verification is required.

## Diagnose Failures

- Use `Langfuse.configured?` to check local client readiness. It does not authenticate.
- Use `Langfuse.client.list_prompts(limit: 1)` for a bounded authenticated request.
- Inspect `Langfuse.client.prompt_cache_stats` or use a cache observer for cache behavior.
- Set `LANGFUSE_DEBUG=true` before initialization for SDK debug logs.

Do not log `Langfuse.configuration.inspect`; it contains credentials.

Cache warming returns failure messages as strings:

```ruby
result = Langfuse::CacheWarmer.new.warm(["greeting", "summary"])
result[:failed].each do |failure|
  warn "#{failure[:name]}: #{failure[:error]}"
end
```

For missing traces, check the host, telemetry switches, sampling, export filters,
and masking errors before investigating ingestion. See [Tracing](TRACING.md) and
[Configuration](CONFIGURATION.md).
