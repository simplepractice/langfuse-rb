#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "json"
require "logger"
require "open3"
require "securerandom"
require "stringio"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "langfuse"

module PR60SamplingValidation
  ROOT = File.expand_path("..", __dir__)
  PYTHON_ROOT = File.join(ROOT, "langfuse-python")

  module_function

  def section(title)
    puts
    puts "=" * 80
    puts title
    puts "=" * 80
  end

  def assert(label, condition)
    if condition
      puts "PASS #{label}"
      return
    end

    warn "FAIL #{label}"
    raise "assertion failed: #{label}"
  end

  def assert_includes(label, haystack, needle)
    assert(label, haystack.include?(needle))
  end

  def config(sample_rate:, flush_interval: 0, batch_size: 50)
    Langfuse::Config.new do |c|
      c.public_key = "pk_test"
      c.secret_key = "sk_test"
      c.base_url = "https://cloud.langfuse.com"
      c.sample_rate = sample_rate
      c.flush_interval = flush_interval
      c.batch_size = batch_size
      c.logger = Logger.new(StringIO.new)
    end
  end

  def sample_decision(sampler, trace_id)
    return true if sampler.nil?

    sampler.should_sample?(
      trace_id: [trace_id].pack("H*"),
      parent_context: nil,
      links: [],
      name: "score",
      kind: OpenTelemetry::Trace::SpanKind::INTERNAL,
      attributes: {}
    ).sampled?
  end

  def cli_json(*args)
    out, err, status = Open3.capture3("npx", "langfuse-cli", "api", *args, "--json")
    raise "langfuse-cli failed: #{args.inspect}\n#{err}" unless status.success?

    parsed = JSON.parse(out)
    parsed.is_a?(Hash) && parsed.key?("body") ? parsed["body"] : parsed
  end

  def cli_status(*args)
    _out, _err, status = Open3.capture3("npx", "langfuse-cli", "api", *args, "--json")
    status
  end

  def cli_auth_args
    server = ENV.fetch("LANGFUSE_BASE_URL", "https://cloud.langfuse.com")
    [
      "--server", server,
      "--username", ENV.fetch("LANGFUSE_PUBLIC_KEY"),
      "--password", ENV.fetch("LANGFUSE_SECRET_KEY")
    ]
  end

  def wait_for_trace(trace_id, timeout: 60, interval: 2)
    deadline = Time.now + timeout
    while Time.now < deadline
      return true if cli_status("traces", "get", trace_id, *cli_auth_args).success?

      sleep interval
    end

    false
  end

  def trace_exists?(trace_id)
    cli_status("traces", "get", trace_id, *cli_auth_args).success?
  end

  def score_count(name)
    body = cli_json("scores", "list", *cli_auth_args, "--name", name, "--limit", "20")
    body.fetch("data", []).length
  end

  def wait_for_score(name, timeout: 60, interval: 2)
    deadline = Time.now + timeout
    while Time.now < deadline
      return true if score_count(name).positive?

      sleep interval
    end

    false
  end

  def configure_live(sample_rate:)
    Langfuse.reset!
    Langfuse.configure do |c|
      c.public_key = ENV.fetch("LANGFUSE_PUBLIC_KEY")
      c.secret_key = ENV.fetch("LANGFUSE_SECRET_KEY")
      c.base_url = ENV.fetch("LANGFUSE_BASE_URL", "https://cloud.langfuse.com")
      c.sample_rate = sample_rate
      c.flush_interval = 1
      c.batch_size = 1
      c.logger = Logger.new(StringIO.new)
    end
  end
end

class RecordingApiClient
  attr_reader :batches

  def initialize
    @batches = []
  end

  def send_batch(events)
    @batches << events
  end

  def events
    batches.flatten
  end
end
