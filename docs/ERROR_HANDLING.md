# Error Handling Guide

Complete guide to handling exceptions and troubleshooting the Langfuse Ruby SDK.

## Exception Hierarchy

All SDK exceptions inherit from `Langfuse::Error`:

```
StandardError
  └── Langfuse::Error
        ├── Langfuse::ConfigurationError
        ├── Langfuse::CacheWarmingError
        └── Langfuse::ApiError
              ├── Langfuse::NotFoundError
              └── Langfuse::UnauthorizedError
```

## Common Exceptions

### `Langfuse::ConfigurationError`

**Cause:** Invalid or missing configuration

**Common scenarios:**
- Missing `public_key` or `secret_key`
- Invalid `cache_backend` value
- Using `:rails` cache backend without Rails

**Example:**

```ruby
Langfuse.configure do |config|
  # Oops, forgot to set keys
end

Langfuse.client
# => Langfuse::ConfigurationError: public_key is required
```

**Solution:**

```ruby
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
end
```

**Validation checklist:**
- `public_key` present and starts with `pk-lf-`
- `secret_key` present and starts with `sk-lf-`
- `cache_backend` is `:memory` or `:rails`
- If `:rails`, Rails is defined

### `Langfuse::UnauthorizedError`

**Cause:** Invalid API credentials (401 response)

**Common scenarios:**
- Wrong `public_key` or `secret_key`
- Keys from different project
- Expired or revoked keys

**Example:**

```ruby
Langfuse.configure do |config|
  config.public_key = "pk-lf-wrong"
  config.secret_key = "sk-lf-wrong"
end

client.get_prompt("greeting")
# => Langfuse::UnauthorizedError: 401 Unauthorized
```

**Solution:**

1. Verify keys in Langfuse UI (Project Settings → API Keys)
2. Check you're using keys from correct project
3. Regenerate keys if compromised

```ruby
# Debug: Print first few chars of keys
config = Langfuse.configuration
puts "Public key: #{config.public_key[0..10]}..."
puts "Secret key: #{config.secret_key[0..10]}..."
```

### `Langfuse::NotFoundError`

**Cause:** Requested resource doesn't exist (404 response)

**Common scenarios:**
- Prompt name misspelled
- Prompt not deployed in Langfuse UI
- Requesting specific version that doesn't exist
- Label doesn't exist

**Example:**

```ruby
client.get_prompt("greting")  # Typo!
# => Langfuse::NotFoundError: Prompt 'greting' not found
```

**Solutions:**

**Option 1:** Fix the name

```ruby
client.get_prompt("greeting")  # Correct spelling
```

**Option 2:** Use fallback for development

```ruby
prompt = client.get_prompt(
  "new-feature",
  fallback: "Hello {{name}}!",
  type: :text
)
# If prompt doesn't exist, uses fallback without error
```

**Option 3:** Graceful degradation

```ruby
begin
  prompt = client.get_prompt("personalized-greeting")
  message = prompt.compile(name: user.name)
rescue Langfuse::NotFoundError => e
  Rails.logger.warn("Prompt not found: #{e.message}")
  message = "Hello #{user.name}!"  # Simple fallback
end
```

**Option 4:** Check available prompts

```ruby
prompts = client.list_prompts
puts "Available prompts:"
prompts.each { |p| puts "  - #{p['name']}" }
```

### `Langfuse::ApiError`

**Cause:** Generic API error (base class for HTTP errors)

**Common scenarios:**
- Network issues
- Langfuse service downtime
- Rate limiting (429)
- Server errors (500, 503)

**Example:**

```ruby
client.get_prompt("greeting")
# => Langfuse::ApiError: 503 Service Unavailable
```

**Solutions:**

**Increase timeout:**

```ruby
Langfuse.configure do |config|
  config.timeout = 10  # Default is 5 seconds
end
```

**Retry with exponential backoff:**

```ruby
def fetch_prompt_with_retry(name, max_retries: 3)
  retries = 0

  begin
    Langfuse.client.get_prompt(name)
  rescue Langfuse::ApiError => e
    retries += 1
    if retries < max_retries
      sleep(2 ** retries)  # 2s, 4s, 8s
      retry
    else
      raise
    end
  end
end
```

**Note:** The SDK already has built-in retry logic for certain errors (429, 503, 504) with exponential backoff. The above is for additional application-level retry logic.

### `Langfuse::CacheWarmingError`

**Cause:** Error during cache warming operation

**Common scenarios:**
- Prompt fetch fails during cache warming
- Network issues during bulk warming

**Example:**

```ruby
warmer = Langfuse::CacheWarmer.new
warmer.warm!(["prompt1", "prompt2", "nonexistent"])
# => Langfuse::CacheWarmingError: Failed to warm cache for 1 prompt(s)
```

**Solutions:**

**Check individual failures:**

```ruby
warmer = Langfuse::CacheWarmer.new
result = warmer.warm(["prompt1", "prompt2"])

if result[:failed].any?
  puts "Failed prompts:"
  result[:failed].each do |failure|
    puts "  #{failure[:name]}: #{failure[:error].class} - #{failure[:error].message}"
  end
end
```

**Graceful warming:**

```ruby
prompts_to_warm = ["critical-prompt", "optional-prompt"]
warmer = Langfuse::CacheWarmer.new

begin
  warmer.warm!(prompts_to_warm)
rescue Langfuse::CacheWarmingError => e
  Rails.logger.warn("Some prompts failed to warm: #{e.message}")
  # Continue - cache will be populated on-demand
end
```

See [CACHING.md](CACHING.md#cache-warming) for warming strategies.

## Retry Strategies

### Built-in Retries

The SDK automatically retries certain operations:

**Prompt fetching (GET requests):**
- Max 2 retries (3 total attempts)
- Retries on: 429, 503, 504, `TimeoutError`, `ConnectionFailed`
- Exponential backoff: `0.05 * 2^retry_count` seconds

**Batch ingestion (POST requests):**
- Max 2 retries (3 total attempts)
- Same error conditions and backoff

You don't need to implement retries for these operations.

### Application-Level Retries

For custom retry logic:

```ruby
class PromptFetcher
  MAX_RETRIES = 3
  BASE_DELAY = 1

  def self.fetch_with_retry(name, version: nil)
    retries = 0

    begin
      Langfuse.client.get_prompt(name, version: version)
    rescue Langfuse::ApiError => e
      retries += 1

      if retries < MAX_RETRIES && retryable?(e)
        delay = BASE_DELAY * (2 ** (retries - 1))
        Rails.logger.info("Retrying prompt fetch (#{retries}/#{MAX_RETRIES}) after #{delay}s: #{e.message}")
        sleep(delay)
        retry
      else
        raise
      end
    end
  end

  def self.retryable?(error)
    error.is_a?(Langfuse::ApiError) &&
      !error.is_a?(Langfuse::UnauthorizedError) &&
      !error.is_a?(Langfuse::NotFoundError)
  end
end
```

**Don't retry:**
- `UnauthorizedError` (credentials won't fix themselves)
- `NotFoundError` (resource doesn't exist)
- `ConfigurationError` (code issue, not transient)

## Fallback Patterns

### Prompt Fallbacks

**Pattern 1: Inline fallback**

```ruby
prompt = client.get_prompt("dynamic-prompt",
  fallback: "Static template with {{variable}}",
  type: :text
)
```

**Pattern 2: Exception-based fallback**

```ruby
begin
  prompt = client.get_prompt("optimized-prompt", label: "production")
  message = prompt.compile(user: user.name)
rescue Langfuse::NotFoundError
  message = "Hello #{user.name}!"
end
```

**Pattern 3: Fallback chain**

```ruby
def get_prompt_with_fallback(primary, fallback_name, default_template)
  client = Langfuse.client

  begin
    client.get_prompt(primary, label: "production")
  rescue Langfuse::NotFoundError
    begin
      client.get_prompt(fallback_name)
    rescue Langfuse::NotFoundError
      client.get_prompt("default", fallback: default_template, type: :text)
    end
  end
end

prompt = get_prompt_with_fallback(
  "new-feature-prompt",
  "standard-prompt",
  "Hello {{name}}!"
)
```

### Circuit Breaker Pattern

Prevent cascading failures:

```ruby
class LangfuseCircuitBreaker
  FAILURE_THRESHOLD = 5
  TIMEOUT = 60  # seconds

  def initialize
    @failures = 0
    @last_failure_time = nil
    @state = :closed  # :closed, :open, :half_open
  end

  def call
    case @state
    when :open
      if Time.now - @last_failure_time > TIMEOUT
        @state = :half_open
      else
        raise Langfuse::ApiError, "Circuit breaker open"
      end
    end

    begin
      result = yield
      on_success
      result
    rescue Langfuse::ApiError => e
      on_failure
      raise
    end
  end

  private

  def on_success
    @failures = 0
    @state = :closed
  end

  def on_failure
    @failures += 1
    @last_failure_time = Time.now
    @state = :open if @failures >= FAILURE_THRESHOLD
  end
end

# Usage
circuit_breaker = LangfuseCircuitBreaker.new

begin
  prompt = circuit_breaker.call do
    Langfuse.client.get_prompt("greeting")
  end
rescue Langfuse::ApiError => e
  prompt = nil  # Use cached or default
end
```

## Debugging Tips

### Enable Debug Logging

```ruby
Langfuse.configure do |config|
  config.logger.level = Logger::DEBUG
end
```

This logs:
- HTTP requests and responses
- Cache hits/misses
- Retry attempts

### Inspect Configuration

```ruby
config = Langfuse.configuration
puts config.inspect
```

### Check Cache State

```ruby
# Not exposed publicly, but useful in console debugging:
cache = Langfuse.client.instance_variable_get(:@prompt_client).instance_variable_get(:@cache)
puts "Cache backend: #{cache.class}"
```

### Test Credentials

```ruby
begin
  prompts = Langfuse.client.list_prompts(limit: 1)
  puts "✓ Credentials valid, found #{prompts.size} prompt(s)"
rescue Langfuse::UnauthorizedError
  puts "✗ Invalid credentials"
rescue Langfuse::ApiError => e
  puts "✗ API error: #{e.message}"
end
```

### Validate Environment Variables

```ruby
required_vars = ['LANGFUSE_PUBLIC_KEY', 'LANGFUSE_SECRET_KEY']
missing = required_vars.reject { |var| ENV[var] }

if missing.any?
  puts "Missing environment variables: #{missing.join(', ')}"
else
  puts "All required environment variables present"
end
```

## See Also

- [CONFIGURATION.md](CONFIGURATION.md) - Configuration options
- [PROMPTS.md](PROMPTS.md) - Fallback strategies for prompts
- [CACHING.md](CACHING.md) - Cache warming errors
- [API_REFERENCE.md](API_REFERENCE.md) - Exception class reference
