# frozen_string_literal: true

module Langfuse
  # Restores SDK-owned background state in a forked child process.
  #
  # @api private
  module ForkSafety
    # Ruby routes Kernel#fork, Process.fork, and IO.popen("-") through
    # Process._fork. Ruby 3.2 documents this override point for monitoring
    # libraries that need before-fork or after-fork behavior.
    module ProcessHook
      def _fork
        pid = super
        Langfuse::ForkSafety.after_fork if pid.zero?
        pid
      end
    end

    class << self
      # Register an SDK resource that implements a private #reset_after_fork method.
      #
      # @param resource [Object] Fork-sensitive SDK resource
      # @return [void]
      def register(resource)
        install!
        registry_mutex.synchronize { registry[resource] = true }
      end

      # Reset every live registered resource in the child process.
      #
      # @return [void]
      def after_fork
        reset_inherited_mutexes
        registry.each_key { |resource| reset_resource(resource) }
      rescue StandardError => e
        Kernel.warn("Langfuse fork reset failed: #{e.class} - #{e.message}")
      end

      private

      def install!
        install_mutex.synchronize do
          Process.singleton_class.prepend(ProcessHook) unless Process.singleton_class.ancestors.include?(ProcessHook)
        end
      end

      def registry
        @registry ||= ObjectSpace::WeakMap.new
      end

      def registry_mutex
        @registry_mutex ||= Mutex.new
      end

      def install_mutex
        @install_mutex ||= Mutex.new
      end

      def reset_inherited_mutexes
        @registry_mutex = Mutex.new
        @install_mutex = Mutex.new
      end

      def reset_resource(resource)
        resource.__send__(:reset_after_fork)
      rescue StandardError => e
        Kernel.warn("Langfuse fork reset failed for #{resource.class}: #{e.class} - #{e.message}")
      end
    end
  end
end
