#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "pr60_sampling_common"

include PR60SamplingValidation

section "langfuse-python source invariants"

python_client = File.read(File.join(PYTHON_ROOT, "langfuse/_client/client.py"))
python_resource_manager = File.read(File.join(PYTHON_ROOT, "langfuse/_client/resource_manager.py"))

assert_includes(
  "python validates trace ids as lowercase 32-char hex",
  python_client,
  'pattern = r"^[0-9a-f]{32}$"'
)

assert_includes(
  "python force-samples legacy/non-valid trace ids",
  python_client,
  "force_sample ="
)
assert_includes(
  "python force-samples non-valid trace ids",
  python_client,
  "not self._is_valid_trace_id(trace_id) if trace_id else True"
)

assert_includes(
  "python samples trace-linked scores with the tracing sampler",
  python_resource_manager,
  "tracer_provider.sampler.should_sample"
)

assert_includes(
  "python does not sample out session/dataset-run-only scores",
  python_resource_manager,
  "do not sample out session / dataset run scores"
)

assert_includes(
  "python uses TraceIdRatioBased for sample_rate below 1",
  python_resource_manager,
  "TraceIdRatioBased(sample_rate)"
)

section "ruby source invariants"

ruby_score_client = File.read(File.join(ROOT, "lib/langfuse/score_client.rb"))
ruby_otel_setup = File.read(File.join(ROOT, "lib/langfuse/otel_setup.rb"))
ruby_sampling = File.read(File.join(ROOT, "lib/langfuse/sampling.rb"))

assert_includes(
  "ruby treats only lowercase 32-char hex as sampleable trace ids",
  ruby_score_client,
  'HEX_TRACE_ID_PATTERN = /\A[0-9a-f]{32}\z/'
)

assert_includes(
  "ruby score sampling is pinned at ScoreClient construction",
  ruby_score_client,
  "@score_sampler = Sampling.build_sampler(config.sample_rate)"
)

assert(
  "ruby score sampling does not consult OtelSetup singleton at enqueue time",
  !ruby_score_client.include?("OtelSetup.tracer_provider")
)

assert_includes(
  "ruby trace setup and score setup share the sampler builder",
  ruby_otel_setup,
  "Sampling.build_sampler(sample_rate)"
)
assert_includes(
  "ruby shared sampler uses TraceIdRatioBased below 1.0",
  ruby_sampling,
  "TraceIdRatioBased.new(sample_rate)"
)

section "SUCCESS"
puts "Static parity invariants match the local langfuse-python implementation."
