# frozen_string_literal: true

module Langfuse
  # Shared SDK identity headers used by REST and OTLP clients.
  module SdkHeaders
    SDK_NAME = "ruby"

    class << self
      # @param public_key [String] Langfuse public API key
      # @return [Hash<String, String>] REST API SDK identity headers
      def rest(public_key:)
        {
          "X-Langfuse-Sdk-Name" => SDK_NAME,
          "X-Langfuse-Sdk-Version" => Langfuse::VERSION,
          "X-Langfuse-Public-Key" => public_key
        }
      end

      # @param public_key [String] Langfuse public API key
      # @return [Hash<String, String>] OTLP exporter SDK identity headers
      def otlp(public_key:)
        {
          "x-langfuse-sdk-name" => SDK_NAME,
          "x-langfuse-sdk-version" => Langfuse::VERSION,
          "x-langfuse-public-key" => public_key
        }
      end
    end
  end
end
