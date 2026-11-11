# Prompt Caching

The SDK caches prompt templates; compilation variables are never part of the cache
key. The key selects a prompt name and either a version or label. Omitting both
uses the `production` cache identity. Passing both raises `ArgumentError`.

## Backends

| Backend | Storage | Limits and sharing |
| --- | --- | --- |
| `:memory` (default) | Thread-safe process-local memory | `cache_max_size` bounds entries. Eviction removes the earliest-expiring entry. |
| `:rails` | The application's `Rails.cache` | Sharing, persistence, and eviction depend on the configured Rails cache store. |
| `:auto` | Rails.cache when available, otherwise memory | Selected when the client builds its cache. |

```ruby
Langfuse.configure do |config|
  config.cache_backend = :memory
  config.cache_ttl = 60
  config.cache_max_size = 1000
end
```

`cache_ttl = 0` disables the client's cache. A per-call positive TTL cannot enable
it afterward; rebuild the client with caching enabled. For Rails, build the client
after `Rails.cache` has been initialized. Redis is one possible store, not a requirement.

## Public Cache Operations

```ruby
client = Langfuse.client
result = client.get_prompt_result("greeting", label: "production")

result.prompt        # TextPromptClient or ChatPromptClient
result.cache_status  # :hit, :miss, :stale, :refresh, :bypass, or :disabled
result.source        # :cache, :api, or :fallback
result.fallback?     # Whether caller-provided fallback content was used
result.logical_key   # "greeting:production"
result.storage_key   # Backend key for the current cache generation
```

Use `get_prompt` when only the prompt is needed. A per-call `cache_ttl` must be a
non-negative Integer. Positive values control the TTL of subsequent writes, not
the lifetime of an already cached entry. `cache_ttl: 0` bypasses reads and writes:

```ruby
prompt = client.get_prompt("greeting", cache_ttl: 0)
result = client.refresh_prompt("greeting", label: "production")
```

`refresh_prompt` bypasses the cache read and writes the fetched prompt to cache,
unless caching is disabled or `cache_ttl: 0` is passed.

## Invalidation

```ruby
client.invalidate_prompt_cache("greeting", label: "production")
client.invalidate_prompt_cache_by_name("greeting")
client.clear_prompt_cache

client.prompt_cache_key("greeting")
client.prompt_cache_stats
client.validate_prompt_cache_backend!
```

Exact invalidation deletes the selected key. Name-wide and whole-cache invalidation
advance generation counters. Old entries become unreachable and expire normally;
there is no scan of the Rails cache. Rails generation values are memoized locally
for up to one second, so cross-process invalidation is not instantaneous.

`create_prompt` and `update_prompt` invalidate the affected name in the client's
cache backend. Edits through the UI or another client/backend become visible after
expiry, explicit invalidation, or `refresh_prompt`.

Rails cache statistics return `nil` for unsupported entry counts; `nil` is not zero.

## Stale-While-Revalidate (SWR)

Set a positive stale window to serve expired-but-usable entries while refreshing
in the background. This works with either backend:

```ruby
Langfuse.configure do |config|
  config.cache_ttl = 60
  config.cache_stale_ttl = 300
  config.cache_refresh_threads = 5
end
```

| Entry state | Fetch behavior |
| --- | --- |
| Within `cache_ttl` | Return the cached template. |
| Within the additional `cache_stale_ttl` window | Return the stale template and schedule a refresh if one is not already running. |
| Missing or beyond both windows | Fetch synchronously from the API. |

Refresh is triggered by a stale read, not by a periodic timer. A failed refresh
leaves the stale entry available until its stale window ends. `:indefinite` is an
approximately 1,000-year stale window, not a guarantee that an entry cannot be evicted.
The compatibility flag `cache_stale_while_revalidate` does not control activation;
`cache_stale_ttl` does.

## Stampede Protection

Background refreshes use locks to avoid duplicate work for the same key. Memory
locks are local to the cache instance. Rails locks use the cache store's
`unless_exist` write and expire after `cache_lock_timeout` seconds.

Without SWR, Rails cache misses also use a lock and a short bounded wait for another
caller to populate the cache. If the wait expires, the caller fetches independently.
Cold misses are therefore not guaranteed to produce only one API request. The
in-memory cold-miss path does not serialize concurrent API fetches.

## Cache Events

```ruby
Langfuse.configure do |config|
  config.prompt_cache_observer = lambda do |event, payload|
    puts "#{event}: #{payload[:name]} (#{payload[:cache_status]})"
  end
end
```

Payloads include the prompt selection, cache keys, backend, status, source, and error
details when relevant. If `ActiveSupport::Notifications` is loaded, the SDK also
instruments `prompt_cache.langfuse`.

## Cache Warming

```ruby
warmer = Langfuse::CacheWarmer.new
result = warmer.warm(["greeting", "summary"], labels: { "greeting" => "production" })
result[:success] # Prompt names
result[:failed]  # Hashes with :name and :error (a String)

warmer.warm!(["greeting"]) # Raises CacheWarmingError if any fetch fails
```

`warm_all(default_label: "production")` discovers names from one `list_prompts`
response; it does not paginate through the project. For a complete project warmup,
paginate `list_prompts(page:, limit:)` and pass the collected names to `warm`.
Use `versions:` or `labels:` hashes to select individual prompts; do not assign
both to the same name.

Warming uses normal cached reads. Use `refresh_prompt` to replace an existing entry.
Warm an in-memory cache in the application process that will use it. A separate
Rake process or Docker build cannot populate another process's memory cache.

For a Rails application using shared cache storage, load the bundled tasks in its
Rakefile if they are not already loaded:

```ruby
load Gem.find_files("tasks/langfuse.rake").first
```

```bash
LANGFUSE_PROMPTS_TO_WARM=greeting,summary bundle exec rake langfuse:warm_cache
bundle exec rake langfuse:clear_cache
```

The tasks require an `environment` task that initializes the application's Langfuse
configuration. Their scope is the configured cache backend.

See [Configuration](CONFIGURATION.md#prompt-caching) for defaults and
[Prompt Management](PROMPTS.md) for fetch and compilation behavior.
