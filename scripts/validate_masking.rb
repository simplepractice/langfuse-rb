#!/usr/bin/env ruby
# frozen_string_literal: true

# One-off validation script for ML-751: Ruby Tracing Masking
#
# Sends a trace with masking enabled to the real Langfuse API,
# then verifies via the langfuse-cli that input/output/metadata were masked.
#
# Usage:
#   LANGFUSE_PUBLIC_KEY=pk_... LANGFUSE_SECRET_KEY=sk_... ruby scripts/validate_masking.rb

require_relative "../lib/langfuse"
require "json"

abort "Set LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY" unless ENV["LANGFUSE_PUBLIC_KEY"] && ENV["LANGFUSE_SECRET_KEY"]

# -- Configure with a mask that redacts every field -------------------------
Langfuse.configure do |config|
  config.public_key  = ENV.fetch("LANGFUSE_PUBLIC_KEY")
  config.secret_key  = ENV.fetch("LANGFUSE_SECRET_KEY")
  config.base_url    = ENV.fetch("LANGFUSE_BASE_URL", "https://cloud.langfuse.com")
  config.mask        = lambda { |data:|
    if data.is_a?(Hash)
      data.transform_values { "[REDACTED]" }
    else
      "[REDACTED]"
    end
  }
end

trace_id = nil

puts "=== Sending masked trace ==="

# -- Create a trace with sensitive data -------------------------------------
Langfuse.observe("masking-validation-trace", input: "secret-input", output: "secret-output",
                                             metadata: { api_key: "sk-secret-123", region: "us-east" }) do |span|
  trace_id = span.trace_id

  span.start_observation("child-generation", {
    model: "gpt-4",
    input: { messages: [{ role: "user", content: "secret prompt" }] },
    output: { content: "secret response" },
    metadata: { token_count: "42", model_version: "v1" }
  }, as_type: :generation) do |gen|
    gen.update(output: { final: "secret final output" })
  end

  span.update_trace(
    input: "updated-secret-input",
    output: "updated-secret-output",
    metadata: { updated_key: "updated-secret-value" }
  )
end

Langfuse.force_flush(timeout: 10)
Langfuse.shutdown(timeout: 10)

puts "Trace ID: #{trace_id}"
puts
puts "=== Local validation ==="
puts "Mask function configured: #{Langfuse.configuration.mask.respond_to?(:call) ? 'YES' : 'NO'}"
puts
puts "To verify via langfuse-cli, run:"
puts "  npx langfuse-cli@latest traces get --traceId #{trace_id}"
puts
puts "Expected: all input/output/metadata fields should contain '[REDACTED]', not the original secrets."
