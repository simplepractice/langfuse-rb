# Prompt Management

Use `Langfuse.client` to fetch, compile, create, and label prompts. Fetches return
`TextPromptClient` or `ChatPromptClient`; API response metadata uses string keys.

## Fetch and Compile

```ruby
client = Langfuse.client
prompt = client.get_prompt("greeting", label: "production")
text = prompt.compile(name: "Alice")

# Fetch and compile in one call.
text = client.compile_prompt("greeting", variables: { name: "Alice" }, label: "production")
```

Choose either `version:` or `label:`, never both. A version pins content; labels can
move between versions. When neither is supplied, the SDK omits both selectors and
uses `production` as its cache identity. Label changes become visible after cache
expiry, invalidation, or an explicit `refresh_prompt`.

Prompt clients expose `name`, `version`, `type`, `prompt`, `config`, `labels`, `tags`,
`commit_message`, `resolution_graph`, and `is_fallback`. `config` contains
application-defined settings; the SDK does not apply them to a model client.

## Template Variables

Templates use Mustache syntax: `{{name}}`, dotted paths such as `{{customer.name}}`,
and sections such as `{{#items}}{{title}}{{/items}}`. Substitution inserts raw text
without HTML escaping.

```ruby
prompt = Langfuse::TextPromptClient.new({
  "name" => "greeting", "version" => 1,
  "prompt" => "Hello {{customer.name}}! {{#items}}{{title}} {{/items}}"
})

prompt.variables # => ["customer.name", "items", "items.title"]
prompt.compile(customer: { name: "Alice" }, items: [{ title: "Ruby" }])
# => "Hello Alice! Ruby "
```

`variables` returns unique references in source order, including section names.
It describes references, not which values are required: sections can be optional.
Invalid Mustache syntax raises `Mustache::Parser::SyntaxError`.

With no compilation arguments, text templates and ordinary chat message content
remain unchanged. Once any arguments are supplied, Mustache renders the template;
missing values render as empty strings. Validate required application inputs yourself.

## Chat Prompts and Message Placeholders

```ruby
prompt = client.create_prompt(
  name: "support-chat",
  type: :chat,
  prompt: [
    { role: :system, content: "Help {{name}} with their question." },
    { type: "placeholder", name: "history" },
    { role: :user, content: "{{question}}" }
  ],
  labels: ["staging"]
)

messages = prompt.compile(
  name: "Alice",
  question: "How do I reset my password?",
  history: [{ role: :assistant, content: "How can I help?" }]
)
```

Compilation returns message hashes with symbol keys and symbol roles. It preserves
extra message fields. A placeholder expands an array of messages in place; `[]`
removes it. Inserted message content is also compiled with the supplied variables.

An unresolved placeholder remains `{ type: "placeholder", name: "history" }` and
logs a warning. Resolve it before sending messages to a model. A non-array value,
non-hash entry, or entry missing a nonempty role or a content key raises
`ArgumentError`. `variables` excludes message placeholder names.

## Create and Promote Versions

```ruby
prompt = client.create_prompt(
  name: "greeting", type: :text, prompt: "Hello {{name}}!",
  config: { temperature: 0.2 }, labels: ["staging"],
  tags: ["onboarding"], commit_message: "Shorten greeting"
)

client.update_prompt(name: prompt.name, version: prompt.version, labels: ["production"])
```

Creating the same name creates another version. `update_prompt` replaces a
version's labels; it does not edit content. Both mutations invalidate that prompt
name in the configured cache backend. For cache scope and refresh behavior, see
[Caching](CACHING.md).

`client.list_prompts(page: 1, limit: 100)` returns one page of metadata as
`Array<Hash>`. It does not fetch prompt content or automatically paginate.

## Fallbacks

```ruby
prompt = client.get_prompt(
  "greeting", fallback: "Hello {{name}}!", type: :text
)
text = prompt.compile(name: "Alice")
puts prompt.is_fallback
```

A fallback requires `type: :text` with a String or `type: :chat` with an array of
messages. It is used after an API error, including missing prompts or failed
authentication. Configuration and argument errors still raise. Fallback clients
have version `0`, empty config, and `is_fallback == true`; they are never cached.

## Link a Prompt to a Generation

```ruby
prompt = client.get_prompt("greeting", label: "production")

Langfuse.observe("greet", as_type: :generation) do |generation|
  generation.update(prompt: prompt, input: prompt.compile(name: "Alice"))
  # Call your model and record its output here.
end
```

The generation records the managed prompt's name and version. Fallback prompts are
not linked to a managed version. See [Tracing](TRACING.md) for model and usage fields
and [API Reference](API_REFERENCE.md#prompts) for full signatures.
