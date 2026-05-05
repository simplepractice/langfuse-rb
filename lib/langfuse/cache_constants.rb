# frozen_string_literal: true

module Langfuse
  # Symbol constants for prompt cache event payloads.
  # Producers (ApiClient, PromptFetchResult) and consumers (observers,
  # ActiveSupport::Notifications subscribers) share these definitions so a
  # rename in one place can't silently desync from the other.
  module CacheStatus
    HIT = :hit
    MISS = :miss
    STALE = :stale
    REFRESH = :refresh
    BYPASS = :bypass
    DISABLED = :disabled
  end

  module CacheSource
    CACHE = :cache
    API = :api
    FALLBACK = :fallback
  end

  module CacheBackend
    MEMORY = "memory"
    RAILS = "rails"
    DISABLED = "disabled"

    # Stat keys backend implementations may not be able to compute. Surfaced in
    # `#stats[:unsupported_counts]` so callers can distinguish "0" from "unknown".
    UNSUPPORTED_COUNT_KEYS = %i[current_generation_entries orphaned_entries total_entries].freeze
  end
end
