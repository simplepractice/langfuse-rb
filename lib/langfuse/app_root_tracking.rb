# frozen_string_literal: true

module Langfuse
  # Owns application-root state for active span trees.
  #
  # @api private
  module AppRootTracking
    # Retains a finished parent until each active child finishes.
    #
    # @api private
    class Tracker
      State = Struct.new(
        :span,
        :trace_claimed,
        :parent_span_id,
        :active_child_count,
        :finished,
        keyword_init: true
      )
      private_constant :State

      def initialize
        @mutex = Mutex.new
        @state_by_span_id = {}
      end

      # @param span [OpenTelemetry::SDK::Trace::Span] The active span
      # @param trace_claimed [Boolean] Whether propagated context already owns the root
      # @return [void]
      def remember(span, trace_claimed:)
        @mutex.synchronize do
          parent_state = @state_by_span_id[span.parent_span_id]
          parent_state.active_child_count += 1 if parent_state
          @state_by_span_id[span.context.span_id] = build_state(span, trace_claimed)
        end
      end

      # @param span_id [String] The finished span ID
      # @return [void]
      def finish(span_id)
        @mutex.synchronize do
          state = @state_by_span_id[span_id]
          state.finished = true if state
          release_finished_state(span_id)
        end
      end

      # @param span_id [String] The possible parent span ID
      # @return [OpenTelemetry::SDK::Trace::Span, nil]
      def parent_span_for(span_id)
        @mutex.synchronize { @state_by_span_id[span_id]&.span }
      end

      # @param span_id [String] The active span ID
      # @return [Boolean]
      def trace_claimed?(span_id)
        @mutex.synchronize { @state_by_span_id[span_id]&.trace_claimed == true }
      end

      # @return [Boolean] Whether the tracker has no active span trees
      def empty?
        @mutex.synchronize { @state_by_span_id.empty? }
      end

      private

      def build_state(span, trace_claimed)
        State.new(
          span: span,
          trace_claimed: trace_claimed,
          parent_span_id: span.parent_span_id,
          active_child_count: 0,
          finished: false
        )
      end

      def release_finished_state(span_id)
        state = @state_by_span_id[span_id]
        return unless state&.finished && state.active_child_count.zero?

        @state_by_span_id.delete(span_id)
        parent_state = @state_by_span_id[state.parent_span_id]
        return unless parent_state

        parent_state.active_child_count -= 1
        release_finished_state(state.parent_span_id)
      end
    end
  end
end
