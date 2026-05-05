# frozen_string_literal: true

module Langfuse
  # Prompt cache event emission for ApiClient.
  #
  # Includers must expose:
  # - `cache_backend_name` — used in {#event_payload} to tag the cache backend
  # - `logger` — used to warn on observer/notifier failures
  module PromptCacheEvents
    # ActiveSupport::Notifications event name used for prompt cache events.
    PROMPT_CACHE_NOTIFICATION = "prompt_cache.langfuse"

    # Configure prompt cache event dispatch. Wraps the observer once into a
    # 1-arg callable so the per-event hot path never re-checks arity.
    #
    # @param cache_observer [#call, nil] Optional observer
    # @return [void]
    def setup_prompt_cache_events(cache_observer:)
      @cache_observer_callable = wrap_cache_observer(cache_observer)
      @active_support_notifications = defined?(ActiveSupport::Notifications) ? ActiveSupport::Notifications : nil
    end

    # Emit a prompt cache event to configured hooks. Accepts an eager payload
    # hash or a block that builds one. The block is only evaluated when at
    # least one listener is active, avoiding hash allocations on the hot path.
    #
    # @param event [Symbol] Event name
    # @param payload [Hash, nil] Event payload (omit when passing a block)
    # @yieldreturn [Hash] Lazily constructed payload
    # @return [void]
    def emit_prompt_cache_event(event, payload = nil)
      observer_callable = @cache_observer_callable
      as_listening = active_support_listening?
      return if observer_callable.nil? && !as_listening

      payload ||= block_given? ? yield : {}
      normalized_payload = payload.merge(event: event.to_sym)
      notify_cache_observer(normalized_payload) if observer_callable
      notify_active_support(normalized_payload) if as_listening
    end

    # Emit a fallback event for a prompt fetch that fell back to caller-provided content.
    #
    # @param key [PromptCacheKey] Logical and storage cache key
    # @param cache_status [Symbol] Cache status to report
    # @param error [StandardError] The error that triggered the fallback
    # @return [void]
    def emit_prompt_fallback_event(key, cache_status:, error:)
      emit_prompt_cache_event(:fallback) do
        event_payload(key, cache_status, CacheSource::FALLBACK,
                      error_class: error.class.name, error_message: error.message)
      end
    end

    private

    # @api private
    def event_payload(key, cache_status, source, extra = {})
      {
        name: key.name,
        version: key.version,
        label: key.resolved_label,
        logical_key: key.logical_key,
        storage_key: key.storage_key,
        backend: cache_backend_name,
        cache_status: cache_status,
        source: source
      }.merge(extra)
    end

    # @api private
    def notify_cache_observer(payload)
      @cache_observer_callable.call(payload)
    rescue StandardError => e
      logger.warn("Langfuse prompt cache observer failed: #{e.class} - #{e.message}")
    end

    # @api private
    def active_support_listening?
      return false unless @active_support_notifications

      notifier = @active_support_notifications.notifier
      # Defensive: notifier stand-ins (test fakes, AS::Notifications forks,
      # very old AS versions) may not implement listening?. Assume they're
      # listening so we still attempt to instrument; notify_active_support
      # rescues failures.
      return true unless notifier.respond_to?(:listening?)

      notifier.listening?(PROMPT_CACHE_NOTIFICATION)
    end

    # @api private
    def notify_active_support(payload)
      @active_support_notifications.instrument(PROMPT_CACHE_NOTIFICATION, payload)
    rescue StandardError => e
      logger.warn("Langfuse ActiveSupport cache notification failed: #{e.class} - #{e.message}")
    end

    # @api private
    def wrap_cache_observer(observer)
      return nil if observer.nil?

      arity = observer.respond_to?(:arity) ? observer.arity : observer.method(:call).arity
      if arity == 1
        ->(payload) { observer.call(payload) }
      else
        ->(payload) { observer.call(payload[:event], payload) }
      end
    end
  end
end
