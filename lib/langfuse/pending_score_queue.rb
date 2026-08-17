# frozen_string_literal: true

module Langfuse
  # Thread-safe bounded queue that keeps scores until delivery succeeds.
  #
  # @api private
  class PendingScoreQueue
    # @return [Integer] Maximum number of pending scores
    attr_reader :capacity

    # @param capacity [Integer] Maximum number of pending scores
    def initialize(capacity:)
      @capacity = capacity
      @events = []
      @mutex = Mutex.new
    end

    # Add an event without waiting for queue capacity.
    #
    # @param event [Hash] Score ingestion event
    # @return [Boolean] true when accepted, false when full
    def push(event)
      @mutex.synchronize do
        return false if @events.length >= capacity

        @events << event
        true
      end
    end

    # @return [Array<Hash>] Stable copy of pending events in insertion order
    def snapshot
      @mutex.synchronize { @events.dup }
    end

    # Remove a delivered prefix while preserving newer events.
    #
    # @param count [Integer] Number of delivered events
    # @return [void]
    def remove_prefix(count)
      @mutex.synchronize { @events.shift(count) }
    end

    # @return [Integer] Number of pending events
    def size
      @mutex.synchronize { @events.size }
    end

    # @return [Boolean] true when no events are pending
    def empty?
      @mutex.synchronize { @events.empty? }
    end
  end
end
