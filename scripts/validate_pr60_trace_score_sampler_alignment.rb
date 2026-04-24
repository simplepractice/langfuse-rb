#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "pr60_sampling_common"

include PR60SamplingValidation

TRACE_IDS = [
  "00000000000000000000000000000001",
  "11111111111111111111111111111111",
  "abcdef1234567890abcdef1234567890",
  "ffffffffffffffffffffffffffffffff"
].freeze

def setup_trace_sampler(sample_rate)
  Langfuse.reset!
  cfg = PR60SamplingValidation.config(sample_rate: sample_rate)
  Langfuse::OtelSetup.setup(cfg)
  Langfuse::OtelSetup.tracer_provider.sampler
end

section "sample_rate=0.0 alignment"

trace_sampler = setup_trace_sampler(0.0)
score_sampler = Langfuse::Sampling.build_sampler(0.0)
TRACE_IDS.each do |trace_id|
  assert(
    "trace and score sampler both drop #{trace_id}",
    !sample_decision(trace_sampler, trace_id) && !sample_decision(score_sampler, trace_id)
  )
end

section "sample_rate=0.5 deterministic alignment"

trace_sampler = setup_trace_sampler(0.5)
score_sampler = Langfuse::Sampling.build_sampler(0.5)
TRACE_IDS.each do |trace_id|
  trace_decision = sample_decision(trace_sampler, trace_id)
  score_decision = sample_decision(score_sampler, trace_id)
  assert("trace and score sampler agree for #{trace_id}", trace_decision == score_decision)
end

section "sample_rate=1.0 alignment"

trace_sampler = setup_trace_sampler(1.0)
score_sampler = Langfuse::Sampling.build_sampler(1.0)
TRACE_IDS.each do |trace_id|
  assert("trace sampler keeps #{trace_id}", sample_decision(trace_sampler, trace_id))
  assert("score sampler keeps #{trace_id} via nil always-on fallback", sample_decision(score_sampler, trace_id))
end

Langfuse.reset!

section "SUCCESS"
puts "Trace and score sampler decisions align across rates."
