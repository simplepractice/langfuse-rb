#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"

ROOT = File.expand_path("..", __dir__)
SCRIPTS = [
  "validate_pr60_python_parity_static.rb",
  "validate_pr60_trace_score_sampler_alignment.rb",
  "validate_pr60_score_sampling_local.rb"
].freeze

LIVE_SCRIPT = "validate_pr60_live_api_sampling.rb"

def run_script(script)
  path = File.join(ROOT, "scripts", script)
  puts
  puts ">>> ruby #{path}"
  system({ "RBENV_VERSION" => ENV.fetch("RBENV_VERSION", "3.2.0") }, "ruby", path)
end

ok = SCRIPTS.all? { |script| run_script(script) }

if ENV["RUN_LIVE"] == "1"
  ok = run_script(LIVE_SCRIPT) && ok
else
  puts
  puts "Skipping #{LIVE_SCRIPT}. Set RUN_LIVE=1 with Langfuse credentials to run API validation."
end

exit(ok ? 0 : 1)
