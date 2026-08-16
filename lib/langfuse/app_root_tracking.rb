# frozen_string_literal: true

module Langfuse
  # Owns application-root state for active span trees.
  #
  # @api private
  module AppRootTracking
    # Defers a finished span until its active ancestors have final export decisions.
    #
    # @api private
    class Tracker
      ReadySpan = Struct.new(:span, :app_root, keyword_init: true)
      private_constant :ReadySpan

      State = Struct.new(
        :span,
        :trace_claimed,
        :parent_span_id,
        :active_child_count,
        :finished,
        :exportable,
        :enqueued,
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

      # Resolve finished spans whose ancestor export decisions are final.
      #
      # @param span [OpenTelemetry::SDK::Trace::Span] The finished span
      # @param exportable [Boolean] Whether the final export filter accepted the span
      # @return [Array<ReadySpan>] Spans that the batch processor can enqueue
      def finish(span, exportable:)
        @mutex.synchronize do
          state = @state_by_span_id[span.context.span_id]
          return [] unless state

          state.finished = true
          state.exportable = exportable
          ready_spans = resolve_ready_spans
          release_finished_states
          ready_spans
        end
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
          finished: false,
          exportable: nil,
          enqueued: false
        )
      end

      def resolve_ready_spans
        @state_by_span_id.values.filter_map do |state|
          next unless state.finished && state.exportable && !state.enqueued

          app_root = app_root_status(state)
          next if app_root.nil?

          state.enqueued = true
          ReadySpan.new(span: state.span, app_root: app_root)
        end
      end

      def app_root_status(state)
        trace_claimed = state.trace_claimed
        parent_span_id = state.parent_span_id
        while (parent_state = @state_by_span_id[parent_span_id])
          return nil unless parent_state.finished
          return false if parent_state.exportable

          trace_claimed = parent_state.trace_claimed
          parent_span_id = parent_state.parent_span_id
        end
        !trace_claimed
      end

      def release_finished_states
        releasable_span_ids = @state_by_span_id.filter_map do |span_id, state|
          span_id if releasable?(state)
        end
        until releasable_span_ids.empty?
          span_id = releasable_span_ids.pop
          state = @state_by_span_id[span_id]
          next unless releasable?(state)

          parent_span_id = release_state(span_id, state)
          releasable_span_ids << parent_span_id if parent_span_id
        end
      end

      def releasable?(state)
        state&.finished && state.active_child_count.zero? && (!state.exportable || state.enqueued)
      end

      def release_state(span_id, state)
        @state_by_span_id.delete(span_id)
        parent_state = @state_by_span_id[state.parent_span_id]
        return unless parent_state

        parent_state.active_child_count -= 1
        state.parent_span_id
      end
    end
  end
end
