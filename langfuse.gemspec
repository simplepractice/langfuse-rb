# frozen_string_literal: true

require_relative "lib/langfuse/version"

Gem::Specification.new do |spec|
  spec.name = "langfuse-rb"
  spec.version = Langfuse::VERSION
  spec.authors = ["SimplePractice"]
  spec.email = ["open-source-langfuse-rb@simplepractice.com"]

  spec.summary = "Ruby SDK for Langfuse - LLM observability and prompt management"
  spec.description = "Official Ruby SDK for Langfuse, providing LLM tracing, observability, " \
                     "and prompt management capabilities"
  spec.homepage = "https://github.com/simplepractice/langfuse-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/simplepractice/langfuse-rb"
  spec.metadata["changelog_uri"] = "https://github.com/simplepractice/langfuse-rb/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.glob(%w[
                          lib/**/*.rb
                          README.md LICENSE
                          CHANGELOG.md
                        ])
  spec.require_paths = ["lib"]

  # Runtime dependencies - HTTP & Templating
  # faraday floor raised to 2.14.3 to exclude CVE-2026-33637 and CVE-2026-54297.
  # This drops Faraday 1.x support; Faraday 2.x needs Ruby >= 3.0, satisfied by our >= 3.2.0 floor.
  spec.add_dependency "faraday", ">= 2.14.3", "< 3"
  spec.add_dependency "faraday-retry", ">= 1.0", "< 3.0"
  spec.add_dependency "mustache", "~> 1.1"
  # json is used directly at runtime (api_client, read_api, score_client) and was only
  # constrained transitively via faraday. Declared explicitly with a >= 2.19.9 floor so
  # consumers cannot resolve json affected by CVE-2026-54696.
  spec.add_dependency "json", "~> 2.19", ">= 2.19.9"

  # Runtime dependencies - Concurrency (for SWR caching)
  # concurrent-ruby floor raised to 1.3.7 to exclude CVE-2026-54904/54905/54906.
  spec.add_dependency "concurrent-ruby", ">= 1.3.7", "< 2.0"

  # Runtime dependencies - OpenTelemetry (for tracing)
  spec.add_dependency "opentelemetry-api", "~> 1.2"
  spec.add_dependency "opentelemetry-common", "~> 0.21"
  spec.add_dependency "opentelemetry-exporter-otlp", "~> 0.28"
  spec.add_dependency "opentelemetry-sdk", "~> 1.4"

  # Runtime dependencies - Standard library compatibility
  spec.add_dependency "base64", "~> 0.2" # Removed from stdlib in Ruby 3.4

  # Development dependencies are specified in Gemfile
end
