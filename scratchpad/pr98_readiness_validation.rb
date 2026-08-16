# frozen_string_literal: true

require "langfuse"

module Pr98ReadinessValidation
  POLL_ATTEMPTS = 12
  POLL_INTERVAL = 1
  RATE_LIMIT_INTERVAL = 20

  module_function

  def run
    credentials = live_credentials
    trace_ids = []

    validate_hostile_configuration(credentials)
    validate_accepted_configuration(credentials, trace_ids)
    validate_tracing_degradation(credentials, trace_ids)
    validate_authentication(credentials)

    puts "TRACE IDS"
    trace_ids.each { |trace_id| puts trace_id }
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

  def validate_accepted_configuration(credentials, trace_ids)
    accepted_variants.each do |name, configure_variant|
      configure(credentials, &configure_variant)
      assert("configured? accepts #{name}") { Langfuse.configured? }
      assert("client constructs for #{name}") { Langfuse.client.is_a?(Langfuse::Client) }
      trace_ids << emit_and_read_trace("pr98-accepted-#{name}")
    end
  end

  def accepted_variants
    {
      "defaults" => ->(_config) {},
      "null-logger" => ->(config) { config.logger = nil }
    }
  end

  def validate_tracing_degradation(credentials, trace_ids)
    configure(credentials) { |config| config.batch_size = nil }
    assert("invalid tracing config degrades without raising") do
      Langfuse.observe("pr98-invalid-tracing") { |span| span.update(output: "no-op") }
      true
    end

    configure(credentials) { |config| config.timeout = nil }
    assert("client-only invalidity does not suppress tracing") do
      trace_id = Langfuse.create_trace_id(seed: "pr98-client-only-#{Time.now.to_f}")
      Langfuse.observe("pr98-client-only-invalid", trace_id: trace_id) { |span| span.update(output: "exported") }
      Langfuse.force_flush(timeout: 10)
      Langfuse.configuration.timeout = Langfuse::Config::DEFAULT_TIMEOUT
      poll_for_trace(trace_id)
      trace_ids << trace_id
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

  def emit_and_read_trace(name)
    trace_id = Langfuse.create_trace_id(seed: "#{name}-#{Time.now.to_f}")
    Langfuse.observe(name, trace_id: trace_id) { |span| span.update(output: "accepted") }
    Langfuse.force_flush(timeout: 10)
    poll_for_trace(trace_id)
    trace_id
  end

  def poll_for_trace(trace_id)
    POLL_ATTEMPTS.times do |attempt|
      return Langfuse.client.get_trace(trace_id)
    rescue Langfuse::NotFoundError
      sleep POLL_INTERVAL unless attempt == POLL_ATTEMPTS - 1
    rescue Langfuse::ApiError => e
      raise unless e.message.include?("429")

      sleep RATE_LIMIT_INTERVAL unless attempt == POLL_ATTEMPTS - 1
    end

    raise "trace #{trace_id} was not retrievable"
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
