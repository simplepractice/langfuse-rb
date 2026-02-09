# Migration Guide: From Hardcoded Prompts to Langfuse

This guide helps you migrate your LLM application from hardcoded prompts to centralized prompt management with Langfuse.

## Table of Contents

- [Why Migrate?](#why-migrate)
- [Migration Strategy](#migration-strategy)
- [Step-by-Step Migration](#step-by-step-migration)
- [Common Patterns](#common-patterns)
- [Rollback Plan](#rollback-plan)
- [Best Practices](#best-practices)

## Why Migrate?

### Problems with Hardcoded Prompts

```ruby
# ❌ Hardcoded prompts are difficult to maintain
class ChatService
  def generate_response(user_message)
    system_prompt = "You are a helpful assistant. Always be polite and concise."

    messages = [
      { role: "system", content: system_prompt },
      { role: "user", content: user_message }
    ]

    openai_client.chat(parameters: { model: "gpt-4", messages: messages })
  end
end
```

**Problems:**
- ❌ Need to redeploy to change prompts
- ❌ No version history or rollback capability
- ❌ Hard to A/B test different prompts
- ❌ Difficult to collaborate with non-technical stakeholders
- ❌ No centralized visibility into all prompts
- ❌ Can't track which version of a prompt generated which output

### Benefits of Langfuse

```ruby
# ✅ Centralized prompt management
class ChatService
  def generate_response(user_message)
    prompt = Langfuse.client.get_prompt("chat-assistant", label: "production")
    messages = prompt.compile(user_message: user_message)

    openai_client.chat(parameters: { model: "gpt-4", messages: messages })
  end
end
```

**Benefits:**
- ✅ Update prompts without redeploying
- ✅ Version history and instant rollback
- ✅ A/B test with labels (production, staging, experimental)
- ✅ Non-technical team members can edit prompts in UI
- ✅ Centralized prompt library with search
- ✅ Automatic tracking of prompt usage in traces

## Migration Strategy

### Phase 1: Setup (Day 1)

1. Install Langfuse SDK
2. Configure API keys
3. Test connectivity

### Phase 2: Create Prompts (Day 2-3)

1. Audit existing hardcoded prompts
2. Create prompts in Langfuse UI
3. Test prompt compilation locally

### Phase 3: Migrate with Fallbacks (Week 1-2)

1. Update code to use Langfuse SDK
2. Keep hardcoded versions as fallbacks
3. Deploy to staging
4. Monitor for errors

### Phase 4: Production Rollout (Week 3)

1. Deploy to production with fallbacks
2. Monitor cache hit rates and latency
3. Verify prompt compilation

### Phase 5: Remove Fallbacks (Week 4+)

1. Confirm stability
2. Remove hardcoded prompts
3. Clean up code

## Step-by-Step Migration

### Step 1: Audit Your Prompts

Create an inventory of all hardcoded prompts:

```ruby
# script/audit_prompts.rb
prompts = []

# Search for common patterns
Dir.glob("app/**/*.rb").each do |file|
  content = File.read(file)

  # Find strings that look like LLM prompts
  if content =~ /(system|user|assistant).*role/i ||
     content =~ /You are a .* assistant/i ||
     content =~ /prompt.*=.*["\'].*\{.*\}/

    prompts << {
      file: file,
      lines: content.lines.select { |l| l =~ /prompt|You are|role/ }
    }
  end
end

puts "Found #{prompts.size} files with potential prompts"
prompts.each do |p|
  puts "\n#{p[:file]}:"
  p[:lines].each { |l| puts "  #{l.strip}" }
end
```

Document each prompt:

| Location | Type | Purpose | Variables | Priority |
|----------|------|---------|-----------|----------|
| `app/services/chat_service.rb` | Chat | Customer support | `user_name`, `issue` | High |
| `app/services/summary_service.rb` | Text | Document summary | `content`, `max_length` | Medium |
| `app/jobs/email_job.rb` | Text | Welcome email | `name`, `verification_link` | High |

### Step 2: Create Prompts in Langfuse

For each hardcoded prompt, create a corresponding Langfuse prompt:

**Before (hardcoded):**

```ruby
# app/services/chat_service.rb
def system_prompt
  "You are a helpful customer support assistant for #{company_name}. " \
  "Always be polite, concise, and helpful. " \
  "User: #{user_name}"
end
```

**After (Langfuse UI):**

Create a prompt in Langfuse with:
- **Name**: `chat-support-system`
- **Type**: Chat
- **Content**:
  ```json
  [
    {
      "role": "system",
      "content": "You are a helpful customer support assistant for {{company_name}}. Always be polite, concise, and helpful."
    },
    {
      "role": "user",
      "content": "User: {{user_name}}\nQuestion: {{user_question}}"
    }
  ]
  ```
- **Labels**: `production`, `v1`
- **Tags**: `support`, `chat`

### Step 3: Migrate Code with Fallbacks

Update your code to use Langfuse, but keep hardcoded prompts as fallbacks:

```ruby
# app/services/chat_service.rb (before)
class ChatService
  def initialize(user)
    @user = user
  end

  def generate_response(question)
    system_prompt = "You are a helpful customer support assistant for Acme Corp. " \
                    "Always be polite, concise, and helpful."

    messages = [
      { role: "system", content: system_prompt },
      { role: "user", content: "User: #{@user.name}\nQuestion: #{question}" }
    ]

    openai_client.chat(parameters: { model: "gpt-4", messages: messages })
  end
end
```

```ruby
# app/services/chat_service.rb (after - with fallback)
class ChatService
  FALLBACK_PROMPT = [
    { "role" => "system", "content" => "You are a helpful customer support assistant for {{company_name}}. Always be polite, concise, and helpful." },
    { "role" => "user", "content" => "User: {{user_name}}\nQuestion: {{user_question}}" }
  ].freeze

  def initialize(user)
    @user = user
  end

  def generate_response(question)
    # Try to fetch from Langfuse, fall back to hardcoded on error
    prompt = Langfuse.client.get_prompt(
      "chat-support-system",
      label: Rails.env.production? ? "production" : "development",
      fallback: FALLBACK_PROMPT,
      type: :chat
    )

    messages = prompt.compile(
      company_name: "Acme Corp",
      user_name: @user.name,
      user_question: question
    )

    openai_client.chat(parameters: { model: "gpt-4", messages: messages })
  end
end
```

### Step 4: Test Locally

Test that prompts compile correctly:

```ruby
# rails console
service = ChatService.new(User.first)
messages = service.send(:fetch_prompt, "What is Ruby?")
puts messages.inspect

# Expected output:
# [
#   { role: :system, content: "You are a helpful customer support assistant for Acme Corp..." },
#   { role: :user, content: "User: Alice\nQuestion: What is Ruby?" }
# ]
```

### Step 5: Deploy to Staging

1. Deploy code with fallbacks to staging
2. Monitor logs for prompt fetches
3. Verify cache behavior
4. Test error scenarios (API down, invalid prompt, etc.)

```ruby
# Check logs for Langfuse activity
# Should see:
# "Fetching prompt: chat-support-system (label: staging)"
# "Cache hit: chat-support-system"
```

### Step 6: Deploy to Production

Deploy to production and monitor closely:

```ruby
# config/initializers/langfuse.rb
Langfuse.configure do |config|
  config.public_key = ENV['LANGFUSE_PUBLIC_KEY']
  config.secret_key = ENV['LANGFUSE_SECRET_KEY']
  config.cache_ttl = 300  # 5 minutes
  config.logger = Rails.logger
end

# Monitor logs
Rails.logger.info("Langfuse initialized with cache_ttl: #{Langfuse.configuration.cache_ttl}s")
```

Monitor key metrics:
- Prompt fetch latency
- Cache hit rate
- Fallback usage (should be 0% if Langfuse is healthy)
- LLM response quality (ensure prompts work as expected)

### Step 7: Remove Fallbacks (Optional)

Once stable for 1-2 weeks, you can remove fallbacks:

```ruby
# app/services/chat_service.rb (final - no fallback)
class ChatService
  def initialize(user)
    @user = user
  end

  def generate_response(question)
    prompt = Langfuse.client.get_prompt(
      "chat-support-system",
      label: Rails.env.production? ? "production" : "development"
    )

    messages = prompt.compile(
      company_name: "Acme Corp",
      user_name: @user.name,
      user_question: question
    )

    openai_client.chat(parameters: { model: "gpt-4", messages: messages })
  end
end
```

**Note:** We recommend keeping fallbacks in critical paths for maximum resilience.

## Common Patterns

### Pattern 1: Simple Text Replacement

**Before:**
```ruby
def welcome_email_body(user_name)
  "Hello #{user_name}! Welcome to our platform. " \
  "Click here to verify your email: #{verification_link}"
end
```

**After:**
```ruby
def welcome_email_body(user_name)
  prompt = Langfuse.client.get_prompt("welcome-email")
  prompt.compile(
    user_name: user_name,
    verification_link: verification_link
  )
end
```

**Langfuse Prompt (Text):**
```
Hello {{user_name}}! Welcome to our platform. Click here to verify your email: {{verification_link}}
```

### Pattern 2: Chat Messages with System Prompt

**Before:**
```ruby
def build_messages(user_input)
  [
    { role: "system", content: "You are a helpful assistant" },
    { role: "user", content: user_input }
  ]
end
```

**After:**
```ruby
def build_messages(user_input)
  prompt = Langfuse.client.get_prompt("assistant-chat")
  prompt.compile(user_input: user_input)
end
```

**Langfuse Prompt (Chat):**
```json
[
  { "role": "system", "content": "You are a helpful assistant" },
  { "role": "user", "content": "{{user_input}}" }
]
```

### Pattern 3: Conditional Prompts

**Before:**
```ruby
def system_prompt(user_tier)
  if user_tier == "premium"
    "You are a premium support assistant with access to advanced features."
  else
    "You are a standard support assistant."
  end
end
```

**After (Option 1 - Multiple Prompts):**
```ruby
def system_prompt(user_tier)
  prompt_name = user_tier == "premium" ? "support-premium" : "support-standard"
  prompt = Langfuse.client.get_prompt(prompt_name)
  prompt.compile
end
```

**After (Option 2 - Single Prompt with Variable):**
```ruby
def system_prompt(user_tier)
  prompt = Langfuse.client.get_prompt("support-system")
  prompt.compile(
    tier: user_tier,
    features: user_tier == "premium" ? "advanced features" : "standard features"
  )
end
```

**Langfuse Prompt:**
```
You are a {{tier}} support assistant with access to {{features}}.
```

### Pattern 4: Multi-Step Prompts

**Before:**
```ruby
def analyze_document(content)
  # Step 1: Extract key points
  extraction_prompt = "Extract key points from: #{content}"
  key_points = llm_call(extraction_prompt)

  # Step 2: Summarize
  summary_prompt = "Summarize these points concisely: #{key_points}"
  summary = llm_call(summary_prompt)

  summary
end
```

**After:**
```ruby
def analyze_document(content)
  # Step 1: Extract key points
  extract_prompt = Langfuse.client.get_prompt("extract-key-points")
  extraction_input = extract_prompt.compile(content: content)
  key_points = llm_call(extraction_input)

  # Step 2: Summarize
  summary_prompt = Langfuse.client.get_prompt("summarize-points")
  summary_input = summary_prompt.compile(points: key_points)
  summary = llm_call(summary_input)

  summary
end
```

### Pattern 5: Prompt with Complex Variables

**Before:**
```ruby
def generate_report(user, data)
  "Report for #{user.name} (#{user.email})\n" \
  "Data points: #{data.count}\n" \
  "Analysis:\n" + data.map { |d| "- #{d[:metric]}: #{d[:value]}" }.join("\n")
end
```

**After:**
```ruby
def generate_report(user, data)
  prompt = Langfuse.client.get_prompt("report-generation")
  prompt.compile(
    user_name: user.name,
    user_email: user.email,
    data_count: data.count,
    data_points: data  # Mustache handles arrays!
  )
end
```

**Langfuse Prompt (Text with Mustache loops):**
```
Report for {{user_name}} ({{user_email}})
Data points: {{data_count}}
Analysis:
{{#data_points}}
- {{metric}}: {{value}}
{{/data_points}}
```

## Rollback Plan

### Emergency Rollback

If Langfuse is down or causing issues:

**Option 1: Use Fallbacks (Recommended)**

If you kept fallbacks, Langfuse failures automatically use hardcoded prompts:

```ruby
prompt = Langfuse.client.get_prompt(
  "greeting",
  fallback: "Hello {{name}}!",
  type: :text
)
# Falls back automatically on error
```

**Option 2: Disable Langfuse Temporarily**

```ruby
# config/initializers/langfuse.rb
# Comment out configuration
# Langfuse.configure do |config|
#   ...
# end

# Update code to detect disabled state
class ChatService
  def generate_response(question)
    if Langfuse.configuration.public_key.present?
      prompt = Langfuse.client.get_prompt("chat-support")
      messages = prompt.compile(question: question)
    else
      # Use hardcoded fallback
      messages = hardcoded_fallback(question)
    end

    openai_client.chat(parameters: { model: "gpt-4", messages: messages })
  end
end
```

**Option 3: Revert Code**

If all else fails, revert to previous deploy with hardcoded prompts.

### Gradual Rollback

If you want to roll back specific prompts:

1. Update Langfuse prompt to match old hardcoded version
2. Or add fallback to specific prompts
3. Or swap to different label (e.g., from "production" to "v1")

```ruby
# Rollback to previous prompt version
prompt = Langfuse.client.get_prompt("chat-support", version: 1)  # Use old version

# Or switch labels
prompt = Langfuse.client.get_prompt("chat-support", label: "fallback")
```

## Best Practices

### 1. Always Use Fallbacks in Critical Paths

```ruby
# ✅ Good - Critical path with fallback
def generate_transaction_confirmation(transaction)
  prompt = Langfuse.client.get_prompt(
    "transaction-confirmation",
    fallback: "Transaction confirmed: {{amount}} to {{recipient}}",
    type: :text
  )
  prompt.compile(amount: transaction.amount, recipient: transaction.recipient)
end

# ❌ Bad - No fallback for critical operation
def generate_transaction_confirmation(transaction)
  prompt = Langfuse.client.get_prompt("transaction-confirmation")
  prompt.compile(amount: transaction.amount, recipient: transaction.recipient)
end
```

### 2. Migrate One Feature at a Time

Don't migrate everything at once. Start with:
- Non-critical features first
- Low-traffic endpoints
- Features with good monitoring

Then gradually expand to critical paths.

### 3. Use Semantic Versioning for Prompts

Track major changes with labels:

- `v1`, `v2`, `v3` - Major prompt rewrites
- `production` - Current production version
- `staging` - Testing version
- `experimental` - A/B test variants

### 4. Keep Variable Names Consistent

Use the same variable names across similar prompts:

```ruby
# Good - Consistent variable names
"chat-support-basic" => {{user_name}}, {{question}}
"chat-support-premium" => {{user_name}}, {{question}}
"email-support" => {{user_name}}, {{question}}

# Bad - Inconsistent variable names
"chat-support-basic" => {{name}}, {{query}}
"chat-support-premium" => {{user}}, {{question}}
"email-support" => {{customer_name}}, {{request}}
```

### 5. Test Prompt Compilation in CI

Add tests that verify prompts compile correctly:

```ruby
# spec/prompts/chat_support_spec.rb
RSpec.describe "Chat Support Prompt" do
  it "compiles with all required variables" do
    prompt = mock_langfuse_prompt("chat-support", [
      { "role" => "system", "content" => "Support assistant" },
      { "role" => "user", "content" => "{{user_name}}: {{question}}" }
    ], type: :chat)

    messages = prompt.compile(user_name: "Alice", question: "Help!")

    expect(messages).to include(hash_including(content: "Alice: Help!"))
  end
end
```

### 6. Monitor Prompt Performance

Track key metrics after migration:

```ruby
# app/middleware/langfuse_monitor.rb
class LangfuseMonitor
  def initialize(app)
    @app = app
  end

  def call(env)
    start = Time.now
    status, headers, response = @app.call(env)
    duration = Time.now - start

    # Log slow requests that might be due to prompt fetching
    if duration > 1.0
      Rails.logger.warn("Slow request (#{duration}s): #{env['PATH_INFO']}")
    end

    [status, headers, response]
  end
end
```

### 7. Document Your Prompts

Add descriptions in Langfuse UI:

- **Purpose**: What this prompt does
- **Variables**: What each variable represents
- **Expected Output**: What the LLM should return
- **Version History**: Why changes were made

### 8. Create a Prompt Registry

Document all prompts in a central location:

```ruby
# config/prompts.yml
prompts:
  chat-support:
    type: chat
    description: "Customer support chat assistant"
    variables:
      - user_name: "Customer's name"
      - question: "Customer's question"
    labels:
      - production
      - staging

  welcome-email:
    type: text
    description: "Welcome email body for new users"
    variables:
      - user_name: "User's name"
      - verification_link: "Email verification URL"
    labels:
      - production
```

## Troubleshooting

### Problem: Prompts not updating after changes

**Solution**: Clear cache or wait for TTL to expire

```ruby
# In Rails console
Langfuse.reset!  # Clears everything
# Or just clear cache
Langfuse.client.instance_variable_get(:@api_client).cache&.clear
```

### Problem: Variables not substituting correctly

**Check**:
1. Variable names match exactly (case-sensitive)
2. Using Mustache syntax: `{{variable}}` not `{variable}`
3. Variables are passed as symbols or strings consistently

```ruby
# Both work:
prompt.compile(name: "Alice")
prompt.compile("name" => "Alice")
```

### Problem: Fallback not triggering

**Check**:
1. Fallback content matches prompt type
2. `type:` parameter is provided
3. Langfuse API is actually unreachable (test with invalid API key)

### Problem: High latency after migration

**Solutions**:
1. Increase cache TTL
2. Warm cache on application boot
3. Use fallbacks for critical paths
4. Check network latency to Langfuse API

## See Also

- [Getting Started](GETTING_STARTED.md) - Installation and first trace
- [Rails Integration](RAILS.md) - Rails-specific patterns
- [Prompts Guide](PROMPTS.md) - Versioning and Mustache templating
- [Caching Guide](CACHING.md) - Cache backends and SWR
- [Langfuse Documentation](https://langfuse.com/docs) - Official Langfuse docs
