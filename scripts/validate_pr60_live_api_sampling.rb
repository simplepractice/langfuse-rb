#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "pr60_sampling_common"

include PR60SamplingValidation

section "credentials"
assert("LANGFUSE_PUBLIC_KEY is set", ENV.key?("LANGFUSE_PUBLIC_KEY"))
assert("LANGFUSE_SECRET_KEY is set", ENV.key?("LANGFUSE_SECRET_KEY"))
puts "base_url=#{ENV.fetch('LANGFUSE_BASE_URL', 'https://cloud.langfuse.com')}"

run_id = SecureRandom.hex(4)

section "sample_rate=1.0 persists trace and trace-linked score"

configure_live(sample_rate: 1.0)
trace_id = Langfuse.create_trace_id(seed: "pr60-live-rate1-#{run_id}")
score_name = "pr60-live-rate1-#{run_id}"

Langfuse.observe("pr60-live-rate1", trace_id: trace_id) do |span|
  span.update(input: { run_id: run_id, rate: 1.0 })
end
Langfuse.create_score(name: score_name, value: 1.0, trace_id: trace_id)
Langfuse.force_flush(timeout: 10)
Langfuse.flush_scores
Langfuse.shutdown(timeout: 10)

assert("rate=1.0 trace appears in API", wait_for_trace(trace_id, timeout: 60, interval: 2))
assert("rate=1.0 trace-linked score appears in API", wait_for_score(score_name, timeout: 60, interval: 2))

section "sample_rate=0.0 drops trace and trace-linked score"

configure_live(sample_rate: 0.0)
trace_id = Langfuse.create_trace_id(seed: "pr60-live-rate0-#{run_id}")
score_name = "pr60-live-rate0-#{run_id}"

Langfuse.observe("pr60-live-rate0", trace_id: trace_id) do |span|
  span.update(input: { run_id: run_id, rate: 0.0 })
end
Langfuse.create_score(name: score_name, value: 1.0, trace_id: trace_id)
Langfuse.force_flush(timeout: 10)
Langfuse.flush_scores
Langfuse.shutdown(timeout: 10)

sleep 6
assert("rate=0.0 trace does not appear in API", !trace_exists?(trace_id))
assert("rate=0.0 trace-linked score does not appear in API", score_count(score_name).zero?)

section "sample_rate=0.0 still sends session-only score"

configure_live(sample_rate: 0.0)
score_name = "pr60-live-session-only-#{run_id}"
Langfuse.create_score(name: score_name, value: 1.0, session_id: "session-#{run_id}")
Langfuse.flush_scores
Langfuse.shutdown(timeout: 10)

sleep 4
assert("session-only score appears despite sample_rate=0.0", wait_for_score(score_name, timeout: 60, interval: 2))

section "SUCCESS"
puts "Live Langfuse API sampling validation passed for run_id=#{run_id}."
