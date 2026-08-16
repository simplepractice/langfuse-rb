# frozen_string_literal: true

require "langfuse"

module Pr98ReadinessValidation
  # Ingestion latency is variable and has been observed well past a minute, so
  # the window is generous. Readback is deferred until every trace is emitted
  # so the wait overlaps instead of being paid once per trace.
  POLL_ATTEMPTS = 40
  POLL_INTERVAL = 3
  RATE_LIMIT_INTERVAL = 20
  SCORE_NAME = "pr98-readiness"

  module_function

  def run
    credentials = live_credentials
    emitted = []

    validate_hostile_configuration(credentials)
    validate_accepted_configuration(credentials, emitted)
    validate_tracing_degradation(credentials, emitted)
    validate_authentication(credentials)
    validate_readback(credentials, emitted)

    puts "TRACE IDS"
    emitted.each { |entry| puts entry.fetch(:trace_id) }
    puts "ALL CHECKS PASSED"
  ensure
    Langfuse.reset!
  end

  def live_credentials
    {
      public_key: ENV.fetch("LANGFUSE_PUBLIC_KEY"),
      secret_key: ENV.fetch("LANGFUSE_SECRET_KEY"),
      base_url: ENV.fetch("LANGFUSE_BASE_URL", Langfuse::Config::DEFAULT_BASE_URL)
    }
  end

  def validate_hostile_configuration(credentials)
    hostile_values.each do |attribute, value|
      configure(credentials) { |config| config.public_send("#{attribute}=", value) }
      assert("configured? rejects #{attribute}") { Langfuse.configured? == false }
    end

    with_environment("LANGFUSE_SAMPLE_RATE" => "invalid") do
      Langfuse.reset!
      assert("configured? contains malformed environment input") { Langfuse.configured? == false }
    end
  end

  def hostile_values
    {
      public_key: 1,
      secret_key: Object.new,
      base_url: [],
      timeout: "5",
      batch_size: nil,
      flush_interval: :ten,
      cache_ttl: "60",
      cache_max_size: false,
      cache_lock_timeout: [],
      cache_stale_ttl: "30",
      cache_refresh_threads: :five,
      cache_backend: :unknown,
      prompt_cache_observer: "invalid",
      mask: 1,
      mask_otel_spans: [],
      should_export_span: {}
    }
  end

  def validate_accepted_configuration(credentials, emitted)
    accepted_variants.each do |name, configure_variant|
      configure(credentials, &configure_variant)
      assert("configured? accepts #{name}") { Langfuse.configured? }
      assert("client constructs for #{name}") { Langfuse.client.is_a?(Langfuse::Client) }
      emitted << emit_trace("pr98-accepted-#{name}", scored: true)
    end
  end

  def accepted_variants
    {
      "defaults" => ->(_config) {},
      "null-logger" => ->(config) { config.logger = nil }
    }
  end

  def validate_tracing_degradation(credentials, emitted)
    configure(credentials) { |config| config.batch_size = nil }
    assert("invalid tracing config degrades without raising") do
      Langfuse.observe("pr98-invalid-tracing") { |span| span.update(output: "no-op") }
      true
    end

    configure(credentials) { |config| config.timeout = nil }
    assert("client-only invalidity does not suppress tracing") do
      entry = emit_trace("pr98-client-only-invalid", scored: false)
      Langfuse.configuration.timeout = Langfuse::Config::DEFAULT_TIMEOUT
      emitted << entry
      true
    end
  end

  def validate_authentication(credentials)
    configure(credentials)
    assert("auth_check accepts valid credentials") { Langfuse.auth_check }
    assert("auth_check! accepts valid credentials") { Langfuse.auth_check! }

    configure(credentials.merge(secret_key: "sk-lf-invalid-#{Time.now.to_i}"))
    assert("auth_check rejects invalid credentials") { Langfuse.auth_check == false }

    with_environment("LANGFUSE_PUBLIC_KEY" => nil, "LANGFUSE_SECRET_KEY" => nil) do
      Langfuse.reset!
      assert("auth_check rejects absent credentials") { Langfuse.auth_check == false }
    end
  end

  def configure(credentials)
    Langfuse.reset!
    Langfuse.configure do |config|
      config.public_key = credentials.fetch(:public_key)
      config.secret_key = credentials.fetch(:secret_key)
      config.base_url = credentials.fetch(:base_url)
      config.tracing_async = false
      yield(config) if block_given?
    end
  end

  # Every accepted configuration must survive the full client path, so scored
  # traces exercise batch_size and flush_interval, which validate! treats as
  # shared client settings rather than tracing-only ones.
  def emit_trace(name, scored:)
    trace_id = Langfuse.create_trace_id(seed: "#{name}-#{Time.now.to_f}")
    Langfuse.observe(name, trace_id: trace_id) do |span|
      span.update(output: "accepted")
      Langfuse.score_active_trace(name: SCORE_NAME, value: 1.0) if scored
    end
    Langfuse.force_flush(timeout: 10)
    Langfuse.client.flush_scores if scored
    { trace_id: trace_id, name: name, scored: scored }
  end

  def validate_readback(credentials, emitted)
    configure(credentials)
    emitted.each do |entry|
      name = entry.fetch(:name)
      trace = poll_for_trace(entry.fetch(:trace_id), expect_score: entry.fetch(:scored))
      assert("trace is retrievable for #{name}") { trace["id"] == entry.fetch(:trace_id) }
      next unless entry.fetch(:scored)

      assert("score is retrievable for #{name}") { score_present?(trace) }
    end
  end

  def poll_for_trace(trace_id, expect_score:)
    POLL_ATTEMPTS.times do |attempt|
      trace = fetch_trace(trace_id)
      return trace if ready?(trace, expect_score)

      sleep(trace == :rate_limited ? RATE_LIMIT_INTERVAL : POLL_INTERVAL) unless attempt == POLL_ATTEMPTS - 1
    end

    raise "trace #{trace_id} was not retrievable#{' with its score' if expect_score}"
  end

  # Returns the trace, nil when it has not been ingested yet, or :rate_limited
  # so the caller can back off harder than the normal poll interval.
  def fetch_trace(trace_id)
    Langfuse.client.get_trace(trace_id)
  rescue Langfuse::NotFoundError
    nil
  rescue Langfuse::ApiError => e
    raise unless e.message.include?("429")

    :rate_limited
  end

  def ready?(trace, expect_score)
    return false unless trace.is_a?(Hash)

    !expect_score || score_present?(trace)
  end

  def score_present?(trace)
    Array(trace["scores"]).any? { |score| score["name"] == SCORE_NAME }
  end

  def assert(label)
    raise "FAIL #{label}" unless yield

    puts "PASS #{label}"
  end

  def with_environment(changes)
    previous = changes.to_h { |key, _value| [key, ENV.fetch(key, nil)] }
    changes.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

Pr98ReadinessValidation.run
