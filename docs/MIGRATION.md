# Move Hardcoded Prompts into Langfuse

## Create and Verify a Version

Create a prompt with the same content, roles, and variable names as the existing
application template. Use `{{variable}}` syntax for substitutions.

```ruby
client = Langfuse.client
prompt = client.create_prompt(
  name: "support-chat", type: :chat, labels: ["staging"],
  prompt: [
    { role: :system, content: "Help {{name}} with their question." },
    { role: :user, content: "{{question}}" }
  ]
)

messages = prompt.compile(name: "Alice", question: "How do I reset my password?")
```

Compare the compiled result with the application's existing model input. Check
message roles, missing variables, and special characters. `prompt.variables`
reports referenced variables but does not validate required inputs.

## Switch Fetching with a Fallback

Keep the previous template as a fallback if the application must continue during
Langfuse API failures:

```ruby
prompt = client.get_prompt(
  "support-chat", label: "production", type: :chat,
  fallback: [
    { role: :system, content: "Help {{name}} with their question." },
    { role: :user, content: "{{question}}" }
  ]
)
messages = prompt.compile(name: "Alice", question: "How do I reset my password?")
```

Check `prompt.is_fallback` to distinguish fallback use from a successful fetch.
Fallbacks cover API failures; they do not hide configuration or argument errors.
To record the managed version used by a model call, pass `prompt:` to the generation
as shown in [Prompt Management](PROMPTS.md#link-a-prompt-to-a-generation).

## Promote or Roll Back

After validating a version, move the application label to it:

```ruby
client.update_prompt(name: "support-chat", version: 2, labels: ["production"])
```

The labels argument replaces the target version's labels. To roll back, move the
label to a known version or fetch that version explicitly with `version:`.
Label-based caches may retain previous content until expiry or invalidation;
rollback is not instantaneous across processes. See [Caching](CACHING.md#invalidation)
for cache scope and refresh options.
