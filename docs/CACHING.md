# Caching Guide

Complete guide to caching strategies in the Langfuse Ruby SDK.

For configuration options, see [CONFIGURATION.md](CONFIGURATION.md).

## Table of Contents

- [Overview](#overview)
- [In-Memory Cache](#in-memory-cache-default)
- [Rails.cache Backend](#railscache-backend-distributed)
- [Stampede Protection](#stampede-protection)
- [Cache Warming](#cache-warming)
- [Performance Considerations](#performance-considerations)
- [Best Practices](#best-practices)

## Overview

The Langfuse Ruby SDK provides two caching backends to optimize prompt fetching:

1. **In-Memory Cache** (default) - Thread-safe, local cache with TTL and LRU eviction
2. **Rails.cache Backend** - Distributed caching with Redis/Memcached

Both backends support TTL-based expiration and automatic stampede protection (Rails.cache only).

## In-Memory Cache (Default)

The default caching backend stores prompts in memory with automatic TTL expiration and LRU eviction.

### Configuration

```ruby
Langfuse.configure do |config|
  config.cache_backend = :memory      # Default
  config.cache_ttl = 60               # Cache for 60 seconds
  config.cache_max_size = 1000        # Max 1000 prompts in memory
end
```

### Features

- **Thread-safe**: Uses Monitor-based synchronization
- **TTL-based expiration**: Automatically expires after configured TTL
- **LRU eviction**: Removes least recently used prompts when max_size is reached
- **Zero dependencies**: No external services required
- **Fast**: ~1ms cache hits

### When to Use

✅ **Perfect for:**
- Single-process applications
- Scripts and background jobs
- Smaller deployments (< 10 processes)
- Development and testing
- When you want zero external dependencies

❌ **Not ideal for:**
- Large-scale deployments (100+ processes)
- Multiple servers sharing the same cache
- When you need cache consistency across processes

### Example

```ruby
# config/initializers/langfuse.rb
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  config.cache_backend = :memory
  config.cache_ttl = 60
  config.cache_max_size = 1000
end

# First call hits the API (~100ms)
prompt1 = Langfuse.client.get_prompt("greeting")

# Second call uses cache (~1ms)
prompt2 = Langfuse.client.get_prompt("greeting")
```

## Rails.cache Backend (Distributed)

For multi-process deployments, use Rails.cache to share cache across all processes and servers.

### Configuration

```ruby
# config/initializers/langfuse.rb
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  config.cache_backend = :rails      # Use Rails.cache (typically Redis)
  config.cache_ttl = 300              # 5 minutes
  config.cache_lock_timeout = 10     # Lock timeout for stampede protection
end
```

### Features

- **Distributed**: Shared cache across all processes and servers
- **Stampede protection**: Automatic distributed locks prevent thundering herd
- **Persistent**: Cache survives application restarts
- **Scalable**: No max_size limit (managed by Redis/Memcached)
- **Consistent**: All processes see the same cached data

### When to Use

✅ **Perfect for:**
- Large Rails apps with many worker processes (Passenger, Puma, Unicorn)
- Multiple servers sharing the same cache
- Deploying with 100+ processes
- Already using Redis for Rails.cache

❌ **Not ideal for:**
- Single-process applications
- Scripts without Rails
- When you want to avoid Redis dependency

### Example

```ruby
# config/initializers/langfuse.rb
Langfuse.configure do |config|
  config.cache_backend = :rails
  config.cache_ttl = 300  # 5 minutes
end

# All 1,200 processes share the same cache in Redis
# First process to request populates cache
# Other 1,199 processes read from Redis
prompt = Langfuse.client.get_prompt("greeting")
```

## Stampede Protection

### The Problem

Without stampede protection, when cache expires in a multi-process environment:

```
Cache expires → 1,200 processes hit cache miss simultaneously
             → 1,200 API calls to Langfuse 💥
```

### The Solution

With Rails.cache backend, stampede protection is **automatic**:

```
Cache expires → Process 1 acquires distributed lock → Calls API
             → Process 2-1200 wait with exponential backoff
             → Process 1 populates cache → Releases lock
             → Process 2-1200 read from cache
Result: 1 API call instead of 1,200! ✨
```

### How It Works

1. **Lock Acquisition**: First process to hit cache miss acquires distributed lock in Redis
2. **Exponential Backoff**: Other processes wait with backoff: 50ms, 100ms, 200ms (max ~350ms)
3. **Cache Population**: Lock holder fetches from API and populates cache
4. **Automatic Release**: Lock is released with `ensure` block (handles crashes)
5. **Fallback**: If lock holder fails, lock auto-expires after timeout

### Configuration

```ruby
Langfuse.configure do |config|
  config.cache_backend = :rails
  config.cache_lock_timeout = 10  # Lock expires after 10s (default)
end
```

### Performance Impact

**SimplePractice Example** (1,200 processes, 50 prompts):

Without stampede protection:
- Cache miss: 1,200 × 50 = 60,000 API calls 💥

With stampede protection:
- Cache miss: 1 × 50 = 50 API calls ✨

**Latency Profile:**

- **Cache hit**: ~1-2ms (Redis read)
- **Cache miss (lock holder)**: ~100ms (API call)
- **Cache miss (waiting)**: ~50-350ms (wait + Redis read)

## Cache Warming

Pre-warm the cache during deployment to prevent cold-start API spikes.

### Auto-Discovery (Recommended)

The SDK can automatically discover ALL prompts in your Langfuse project:

```bash
# Rake task - warms all prompts with "production" label
bundle exec rake langfuse:warm_cache_all
```

```ruby
# Programmatically
warmer = Langfuse::CacheWarmer.new
results = warmer.warm_all

puts "Cached #{results[:success].size} prompts"
# => Cached 12 prompts (with "production" label)

# Warm with different label
results = warmer.warm_all(default_label: "staging")

# Warm latest versions (no label)
results = warmer.warm_all(default_label: nil)
```

### Manual Prompt List

Specify exact prompts to warm:

```bash
# Via rake task
bundle exec rake langfuse:warm_cache[greeting,conversation,rag-pipeline]

# Via environment variable
LANGFUSE_PROMPTS_TO_WARM=greeting,conversation rake langfuse:warm_cache
```

```ruby
# Programmatically
warmer = Langfuse::CacheWarmer.new
results = warmer.warm(['greeting', 'conversation', 'rag-pipeline'])

puts "Cached #{results[:success].size} prompts"
# => Cached 3 prompts
```

### With Specific Versions or Labels

```ruby
# Override label for specific prompts
warmer.warm_all(
  default_label: "production",
  labels: { 'greeting' => 'staging' }  # greeting uses staging
)

# Use specific versions (takes precedence over label)
warmer.warm_all(
  versions: { 'greeting' => 2 }  # greeting uses version 2
)
```

### Strict Mode

Raise on failures (useful for CI/CD):

```ruby
warmer.warm!(['greeting', 'conversation'])  # Raises CacheWarmingError if any fail
```

### Deployment Integration

**Capistrano:**

```ruby
# config/deploy.rb
after 'deploy:published', 'langfuse:warm_cache'

namespace :langfuse do
  task :warm_cache do
    on roles(:app) do
      within release_path do
        with rails_env: fetch(:rails_env) do
          execute :rake, 'langfuse:warm_cache_all'
        end
      end
    end
  end
end
```

**Docker/K8s:**

```dockerfile
# Dockerfile
RUN bundle exec rake langfuse:warm_cache_all
```

## Configuration

See [CONFIGURATION.md](CONFIGURATION.md) for all cache-related configuration options:
- `cache_backend` - `:memory` or `:rails`
- `cache_ttl` - Time-to-live in seconds
- `cache_max_size` - Max prompts (in-memory only)
- `cache_lock_timeout` - Lock timeout (Rails.cache only)

## Performance Considerations

### Latency Comparison

**In-Memory Cache:**
- Cache hit: ~1ms
- Cache miss: ~100ms (API call)

**Rails.cache (Redis):**
- Cache hit: ~1-2ms (Redis read)
- Cache miss (lock holder): ~100ms (API call)
- Cache miss (waiting): ~50-350ms (wait + Redis read)

### Memory Usage

**In-Memory Cache:**
- ~10KB per prompt (varies by size)
- 1,000 prompts = ~10MB
- Multiplied by number of processes

**Rails.cache:**
- Single copy in Redis
- No per-process memory overhead

### Cache Eviction

**In-Memory Cache:**
- TTL expiration + LRU eviction
- Evicts least recently used when max_size reached

**Rails.cache:**
- TTL expiration only
- No max_size limit (Redis manages memory)

## Best Practices

### 1. Choose the Right Backend

```ruby
# Single process or script
config.cache_backend = :memory

# Large Rails app with many processes
config.cache_backend = :rails
```

### 2. Set Appropriate TTL

```ruby
# Development: short TTL for fast iteration
config.cache_ttl = Rails.env.development? ? 30 : 300

# Production: longer TTL for stability
config.cache_ttl = Rails.env.production? ? 600 : 60
```

### 3. Warm Cache on Deployment

```bash
# In your deploy script
bundle exec rake langfuse:warm_cache_all
```

### 4. Monitor Cache Performance

```ruby
# Log cache hits/misses
Rails.logger.info "Fetching prompt: #{name} (cache: #{cache_hit? ? 'HIT' : 'MISS'})"
```

### 5. Handle Cache Failures Gracefully

```ruby
# Always provide fallbacks for critical prompts
prompt = Langfuse.client.get_prompt(
  "critical-prompt",
  fallback: "Safe default value",
  type: :text
)
```

### 6. Clear Cache When Needed

```ruby
# Rails console
Langfuse.client.instance_variable_get(:@api_client).cache&.clear

# Or use rake task
rake langfuse:clear_cache
```

### 7. Test Cache Behavior

```ruby
# RSpec example
it "caches prompts" do
  # First call hits API
  expect(api_client).to receive(:get_prompt).once
  prompt1 = client.get_prompt("greeting")

  # Second call uses cache
  prompt2 = client.get_prompt("greeting")

  expect(prompt1.name).to eq(prompt2.name)
end
```

## Troubleshooting

### Cache Not Working

**Symptom**: Every request hits the API

**Solutions**:
1. Check `cache_ttl > 0`
2. Verify cache backend is configured correctly
3. For Rails.cache, ensure Redis is running

### High Memory Usage

**Symptom**: Application memory grows over time

**Solutions**:
1. Reduce `cache_max_size` (in-memory cache)
2. Switch to Rails.cache backend
3. Reduce `cache_ttl`

### Stale Prompts After Update

**Symptom**: Changes in Langfuse UI not reflected

**Solutions**:
1. Wait for TTL to expire
2. Clear cache manually: `rake langfuse:clear_cache`
3. Reduce `cache_ttl` in development

### Stampede Protection Not Working

**Symptom**: Still seeing many API calls

**Solutions**:
1. Ensure `cache_backend = :rails` (stampede protection only works with Rails.cache)
2. Verify Redis is accessible
3. Check `cache_lock_timeout` is sufficient

## Additional Resources

- [Main README](../README.md) - SDK overview
- [Rails Integration Guide](RAILS.md) - Rails-specific patterns
- [Tracing Guide](TRACING.md) - LLM observability
- [Architecture Guide](ARCHITECTURE.md) - Design decisions

## Questions?

Open an issue on [GitHub](https://github.com/langfuse/langfuse-ruby/issues) if you have questions or need help with caching.
