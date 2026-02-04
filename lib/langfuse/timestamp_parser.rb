# frozen_string_literal: true

require "time"

module Langfuse
  # Shared timestamp parsing for API response data objects
  module TimestampParser
    private

    def parse_timestamp(value)
      return nil if value.nil?

      Time.parse(value)
    rescue ArgumentError
      value
    end
  end
end
