#!/usr/bin/env ruby
# frozen_string_literal: true

require "opentelemetry/sdk"
require_relative "pr60_sampling_common"

include PR60SamplingValidation

LOWER_TRACE_ID = "abcdef1234567890abcdef1234567890"
UPPER_TRACE_ID = "ABCDEF1234567890ABCDEF1234567890"

def score_client(sample_rate)
  api = RecordingApiClient.new
  client = Langfuse::ScoreClient.new(api_client: api, config: PR60SamplingValidation.config(sample_rate: sample_rate))
  [client, api]
end

section "trace-linked score sampling"

client, api = score_client(0.0)
client.create(name: "drop-lowercase-trace", value: 1.0, trace_id: LOWER_TRACE_ID)
client.flush
assert("sample_rate=0.0 drops lowercase 32-hex trace-linked scores", api.events.empty?)

client.create(name: "keep-session-only", value: 1.0, session_id: "session-1")
client.create(name: "keep-dataset-run-only", value: 1.0, dataset_run_id: "dataset-run-1")
client.create(name: "keep-no-trace", value: 1.0)
client.flush
assert("sample_rate=0.0 keeps non-trace-linked scores", api.events.length == 3)

client, api = score_client(0.0)
client.create(name: "keep-legacy-string", value: 1.0, trace_id: "legacy-trace-id")
client.create(name: "keep-uppercase", value: 1.0, trace_id: UPPER_TRACE_ID)
client.flush
assert("legacy and uppercase trace ids are force-sampled like langfuse-python", api.events.length == 2)

section "host OpenTelemetry sampler does not steer Langfuse score emission"

original_provider = OpenTelemetry.tracer_provider
OpenTelemetry.tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
  sampler: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON
)
client, api = score_client(0.0)
client.create(name: "host-always-on-does-not-override", value: 1.0, trace_id: LOWER_TRACE_ID)
client.flush
assert("host ALWAYS_ON does not make sample_rate=0.0 send trace-linked scores", api.events.empty?)

OpenTelemetry.tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
  sampler: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF
)
client, api = score_client(1.0)
client.create(name: "host-always-off-does-not-override", value: 1.0, trace_id: LOWER_TRACE_ID)
client.flush
assert("host ALWAYS_OFF does not make sample_rate=1.0 drop trace-linked scores", api.events.length == 1)
OpenTelemetry.tracer_provider = original_provider

section "per-client isolation"

permissive_client, permissive_api = score_client(1.0)
strict_client, strict_api = score_client(0.0)

permissive_client.create(name: "permissive", value: 1.0, trace_id: LOWER_TRACE_ID)
strict_client.create(name: "strict", value: 1.0, trace_id: LOWER_TRACE_ID)
permissive_client.flush
strict_client.flush

assert("sample_rate=1.0 client sends independently", permissive_api.events.length == 1)
assert("sample_rate=0.0 client drops independently", strict_api.events.empty?)

section "config mutation after client construction"

cfg = config(sample_rate: 1.0)
api = RecordingApiClient.new
client = Langfuse::ScoreClient.new(api_client: api, config: cfg)
cfg.sample_rate = 0.0
client.create(name: "pinned", value: 1.0, trace_id: LOWER_TRACE_ID)
client.flush
assert("score sampler remains pinned after config.sample_rate mutation", api.events.length == 1)

section "SUCCESS"
puts "Local score sampling invariants passed."
