# frozen_string_literal: true

module Langfuse
  # Builds an API client only when a non-telemetry operation needs it.
  #
  # @api private
  class DeferredApiClient
    # @yield Builds and validates the real API client
    # @return [DeferredApiClient]
    def initialize(&factory)
      @factory = factory
      @mutex = Mutex.new
    end

    # Avoid building an unused API client during disabled-client shutdown.
    #
    # @return [void]
    def shutdown
      @mutex.synchronize { @client }&.shutdown
    end

    # @api private
    def method_missing(name, ...)
      return super unless ApiClient.public_instance_methods.include?(name)

      client.public_send(name, ...)
    end

    # @api private
    def respond_to_missing?(name, include_private = false)
      ApiClient.public_instance_methods.include?(name) || super
    end

    private

    def client
      @mutex.synchronize { @client ||= @factory.call }
    end
  end
end
