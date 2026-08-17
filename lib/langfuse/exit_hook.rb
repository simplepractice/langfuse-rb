# frozen_string_literal: true

require_relative "fork_safety"

module Langfuse
  # Flushes SDK telemetry during normal process exit.
  #
  # @api private
  module ExitHook
    class << self
      # Install the process callback once and enable it.
      #
      # @return [void]
      def install!
        mutex.synchronize do
          return if @installed

          Kernel.at_exit { run }
          @installed = true
          @active = false
        end
      end

      # Enable the installed callback for the current SDK lifecycle.
      #
      # @return [void]
      def enable
        mutex.synchronize { @active = true }
      end

      # Disable the callback after an explicit shutdown or reset.
      #
      # @return [void]
      def disable
        mutex.synchronize { @active = false }
      end

      # Run the callback once without allowing shutdown errors to escape.
      #
      # @return [void]
      def run
        return unless consume_active_hook

        Langfuse.shutdown
      rescue StandardError => e
        warn_failure(e)
      end

      private

      def consume_active_hook
        mutex.synchronize do
          active = @active
          @active = false
          active
        end
      end

      def reset_after_fork
        @mutex = Mutex.new
      end

      def mutex
        @mutex ||= Mutex.new
      end

      def warn_failure(error)
        Kernel.warn("Langfuse exit flush failed: #{error.class} - #{error.message}")
      rescue StandardError
        nil
      end
    end

    install!
    ForkSafety.register(self)
  end
end
