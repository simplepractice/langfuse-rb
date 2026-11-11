# Metadata encoding and compatibility

The default `:legacy` encoding keeps existing metadata attributes and filters.
Use `:json` to preserve JSON values through SDK propagation and serialization:

```ruby
Langfuse.configure do |config|
  config.public_key = ENV["LANGFUSE_PUBLIC_KEY"]
  config.secret_key = ENV["LANGFUSE_SECRET_KEY"]
  config.metadata_encoding = :json
end

Langfuse.propagate_attributes(metadata: { tenant: { tier: "pro" }, retries: 2, cached: false }) do
  Langfuse.observe("request", metadata: { sources: ["search", "cache"], optional: nil }) do |span|
    span.update(metadata: { completed: true })
  end
end
```

Select the encoding before starting work. Do not change it inside an active
observation or propagation scope. This setting applies to observation, trace,
experiment, and experiment-item metadata. Score and dataset HTTP payloads are
unaffected.

## Backend contract

Langfuse's per-key JSON decoding currently recognizes Python SDK v5+ and
JavaScript SDK v6+, not Ruby. Changing the Ruby version or ingestion-version
header does not enable it. The Ruby SDK continues to identify itself as `ruby`
with its actual gem version and `langfuse-rb` instrumentation scope.

JSON mode instead sends a complete JSON object in each base attribute:
`langfuse.observation.metadata`, `langfuse.trace.metadata`,
`langfuse.experiment.metadata`, and `langfuse.experiment.item.metadata`.
The backend parses these objects independently of SDK identity. No Python or
JavaScript identity override or backend allowlist change is required.

This contract was checked against Langfuse Cloud **4.78.0**, including CLI
readback and metadata filters. Older self-hosted versions have not been verified;
keep the default mode until the same checks pass on your deployment. Do not
infer Ruby compatibility from the Python SDK's minimum server version.

Source references, pinned to the backend revision inspected:

- [SDK identities and JSON-decoding version gate](https://github.com/langfuse/langfuse/blob/46194ed28deccb23b569e5c2e3be6e0bab048053/packages/shared/src/server/ingestion/ingestionAttribution.ts)
- [Object parsing, prefixed attributes, and experiment extraction](https://github.com/langfuse/langfuse/blob/46194ed28deccb23b569e5c2e3be6e0bab048053/packages/shared/src/server/otel/OtelIngestionProcessor.ts)

The source revision establishes the implementation contract; the Cloud runtime
was identified by its health endpoint, not by a deployed commit SHA.

## Stored values and filters

SDK preservation is distinct from server storage and API presentation. On the
verified server, nested objects become dotted metadata paths and stored leaves
are strings. The observations API parses JSON-looking leaves on readback;
experiment APIs return the stored strings.

| JSON input | Observations API | Experiment API | Equality filter value |
| --- | --- | --- | --- |
| `"prod"` | `"prod"` | `"prod"` | `"prod"` |
| `"123"` | `123` | `"123"` | `"123"` |
| `5` | `5` | `"5"` | `"5"` |
| `false` | `false` | `"false"` | `"false"` |
| `[1, "two", false, null]` | Array | `"[1,\"two\",false,null]"` | `"[1,\"two\",false,null]"` |
| `{ nested: { leaf: "value" } }` | `nested.leaf: "value"` | Same path and string | Key `nested.leaf`, value `"value"` |
| `null` under a key | `""` | `""` | `""` |

Thus, numeric-looking strings and numbers cannot be distinguished by these
stored metadata filters. A null leaf is not returned as Ruby `nil`; nulls inside
arrays remain null. Numeric and boolean range/type comparisons are not provided
by this encoding change. Use `stringObject` metadata filters with string values
on the observations endpoint. The verified public experiments endpoint rejects
metadata filters; its supported filter columns are `id`, `name`, and `datasetId`.

Legacy mode recursively flattens hashes, serializes arrays, stringifies scalar
leaves, and omits nil leaves. JSON mode keeps nil leaves on the wire, so new data
can contain empty-string leaves after ingestion. Existing data is not rewritten.
Review saved filters, null/missing checks, and consumers of raw OpenTelemetry
attributes before opting in. Top-level metadata should be a hash; the backend
does not retain primitive top-level metadata.

In JSON mode, updates merge top-level metadata keys. Replacing a nested key replaces its
entire value, and a nil value explicitly replaces that key in JSON mode. An
omitted metadata argument does not change it. Legacy updates continue to merge
flattened paths. Concurrent SDK updates to one span preserve independent keys.

## Propagation and baggage

Propagated metadata accepts JSON-serializable values in both modes. Values are
copied and frozen when the scope is entered, so later caller mutation does not
change the propagated context. Nested scopes merge top-level keys in JSON mode
and flattened paths in legacy mode. Both restore the outer context for
subsequent children.

In JSON mode, the 200-character limit applies to each encoded value, including
quotes and escapes. A plain string can contain at most 198 characters. Legacy
mode applies the limit after flattening: string leaves can contain 200 characters,
and arrays use their JSON length. A larger nested object is accepted when its
individual leaves fit. Oversized encoded values are dropped with a warning.
Invalid JSON, including circular structures and non-finite numbers, drops the
containing top-level entry; valid sibling entries still propagate.

With `as_baggage: true`, JSON mode encodes each `langfuse_metadata_<key>` value as
JSON, including strings. The receiving Ruby SDK reconstructs the object metadata
attribute. Configure the same mode at both ends. Legacy unquoted strings that
are not valid JSON remain strings, but unquoted `123`, `false`, or `null` are
ambiguous to a JSON-mode receiver. Coordinate migration with other services.
Legacy mode uses the same flattened paths and string values for context and
baggage. For example, `{ tenant: { tier: "pro" } }` becomes the baggage entry
`langfuse_metadata_tenant.tier=pro`; arrays remain JSON strings. This keeps local
children and baggage-only receivers consistent. Empty or fully rejected metadata
does not create attributes or replace an inherited scope.

## Masking and custom exporters

`mask` still receives the original metadata object before encoding. Propagated
metadata still bypasses this hook; redact it before propagation or use
`mask_otel_spans`. Masking failures replace the entire metadata value, without
merging old sensitive fields back into it. The backend may discard that scalar
replacement, but the original metadata is not exported.

Default legacy hooks keep their existing dotted attributes. In JSON mode,
`should_export_span`, `mask_otel_spans`, and custom exporters see the complete
JSON string at the base attribute. Update hooks before enabling the mode:

```ruby
Langfuse.configure do |config|
  config.metadata_encoding = :json
  config.mask_otel_spans = lambda do |params:|
    patches = params.spans.filter_map do |identifier, span|
      key = "langfuse.trace.metadata"
      next unless span.attributes.key?(key)

      metadata = JSON.parse(span.attributes.fetch(key))
      next unless metadata.is_a?(Hash)

      metadata.delete("secret")
      [identifier, Langfuse::OtelSpanPatch.new(set_attributes: { key => JSON.generate(metadata) })]
    end.to_h
    Langfuse::MaskOtelSpansResult.new(span_patches: patches)
  end
end
```

Repeat for each metadata domain that your hook protects. Delete the base attribute
to remove that domain entirely. Hook replacements must be serialized strings,
not Ruby hashes. Manually added dotted metadata attributes can override object
keys during ingestion, so inspect and redact those separately if your application
adds them. Export hooks still operate on a copy and retain fail-closed behavior.
