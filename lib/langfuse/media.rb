# frozen_string_literal: true

require "base64"
require "digest"
require "faraday"
require "json"

module Langfuse
  # Parsed Langfuse media reference token.
  MediaReference = Struct.new(:media_id, :source, :content_type, keyword_init: true)

  # Dependency-light wrapper for media references used in trace input/output/metadata.
  class Media
    REFERENCE_PATTERN = /@@@langfuseMedia:.+?@@@/
    PREFIX = "@@@langfuseMedia:"
    SUFFIX = "@@@"

    # @return [Object, nil] Optional application object wrapped by this media helper
    attr_reader :obj

    # @return [String] Source type: base64_data_uri, bytes, or file
    attr_reader :source

    # @return [String] MIME type
    attr_reader :content_type

    # @return [String] Raw media bytes
    attr_reader :content_bytes

    # @param obj [Object, nil] Optional application object to carry alongside media content
    # @param base64_data_uri [String, nil] Base64 data URI
    # @param content_type [String, nil] MIME type when using bytes or file_path
    # @param content_bytes [String, nil] Raw media bytes
    # @param file_path [String, nil] File path to read as media bytes
    # @return [Media]
    # @raise [ArgumentError] when no valid media source is provided
    def initialize(obj: nil, base64_data_uri: nil, content_type: nil, content_bytes: nil, file_path: nil)
      @obj = obj
      assign_content(base64_data_uri: base64_data_uri, content_type: content_type,
                     content_bytes: content_bytes, file_path: file_path)
      raise ArgumentError, "media content and content_type are required" unless valid?
    end

    # @return [Boolean] true when the media has bytes, content type, and source
    def valid?
      !content_bytes.nil? && !content_type.nil? && !source.nil?
    end

    # @return [Integer] Media byte length
    def content_length
      content_bytes.bytesize
    end

    # @return [String] Base64-encoded SHA256 digest
    def content_sha256_hash
      Base64.strict_encode64(Digest::SHA256.digest(content_bytes))
    end

    # @return [String] Deterministic Langfuse media ID derived from content hash
    def media_id
      content_sha256_hash.tr("+/", "-_")[0, 22]
    end

    # @return [String] Langfuse media reference token
    def reference_string
      "#{PREFIX}type=#{content_type}|id=#{media_id}|source=#{source}#{SUFFIX}"
    end
    alias tag reference_string

    # @return [String] Media content as a base64 data URI
    def base64_data_uri
      "data:#{content_type};base64,#{Base64.strict_encode64(content_bytes)}"
    end

    # @return [String] JSON representation compatible with JS/Python SDK media wrappers
    def to_json(*)
      base64_data_uri.to_json(*)
    end

    class << self
      # Parse a Langfuse media reference token.
      #
      # @param reference_string [String] Reference token
      # @return [MediaReference] Parsed reference
      # @raise [ArgumentError] when the token is malformed
      def parse_reference_string(reference_string)
        validate_reference_string!(reference_string)
        parsed = reference_string[PREFIX.length...-SUFFIX.length].split("|").to_h { |pair| pair.split("=", 2) }
        unless parsed.values_at("type", "id", "source").all?
          raise ArgumentError, "Missing required fields in reference string"
        end

        MediaReference.new(media_id: parsed.fetch("id"), source: parsed.fetch("source"),
                           content_type: parsed.fetch("type"))
      rescue NoMethodError
        raise ArgumentError, "Reference string is not a string"
      end

      # Resolve Langfuse media reference tokens in a nested object.
      #
      # @param obj [Object] Object to traverse
      # @param client [Client] Langfuse client used to fetch media records
      # @param resolve_with [Symbol, String] Only :base64_data_uri is supported
      # @param max_depth [Integer] Maximum nested traversal depth
      # @param content_fetch_timeout [Integer] Media download timeout in seconds
      # @return [Object] Copy of obj with resolvable references replaced
      # @raise [ArgumentError] when resolve_with is unsupported
      def resolve_references(obj, client:, resolve_with: :base64_data_uri, max_depth: 10, content_fetch_timeout: 10)
        raise ArgumentError, "resolve_with must be :base64_data_uri" unless resolve_with.to_s == "base64_data_uri"

        logger = client.respond_to?(:config) ? client.config.logger : nil
        traverse(obj, client, 0, max_depth, content_fetch_timeout, logger)
      end

      private

      def validate_reference_string!(reference_string)
        raise ArgumentError, "Reference string is empty" if reference_string.nil? || reference_string.empty?
        unless reference_string.start_with?("#{PREFIX}type=")
          raise ArgumentError, "Reference string does not start with '#{PREFIX}type='"
        end
        raise ArgumentError, "Reference string does not end with '#{SUFFIX}'" unless reference_string.end_with?(SUFFIX)
      end

      def traverse(obj, client, depth, max_depth, timeout, logger)
        return obj if depth > max_depth
        return resolve_string(obj, client, timeout, logger) if obj.is_a?(String)
        return obj.map { |item| traverse(item, client, depth + 1, max_depth, timeout, logger) } if obj.is_a?(Array)

        if obj.is_a?(Hash)
          return obj.transform_values { |value| traverse(value, client, depth + 1, max_depth, timeout, logger) }
        end

        obj
      end

      def resolve_string(value, client, timeout, logger)
        value.gsub(REFERENCE_PATTERN) do |reference_string|
          resolve_reference_string(reference_string, client, timeout)
        rescue StandardError => e
          logger&.warn("Langfuse media reference resolution failed: #{e.message}")
          reference_string
        end
      end

      def resolve_reference_string(reference_string, client, timeout)
        reference = parse_reference_string(reference_string)
        media = client.get_media(reference.media_id)
        response = media_download_connection(media.fetch("url"), timeout).get
        raise ApiError, "Media download failed (#{response.status})" unless response.status == 200

        "data:#{media.fetch('contentType')};base64,#{Base64.strict_encode64(response.body.b)}"
      end

      def media_download_connection(url, timeout)
        Faraday.new(url: url) do |conn|
          conn.options.timeout = timeout
          conn.adapter Faraday.default_adapter
        end
      end
    end

    private

    def assign_content(base64_data_uri:, content_type:, content_bytes:, file_path:)
      if base64_data_uri
        @content_bytes, @content_type = parse_base64_data_uri(base64_data_uri)
        @source = "base64_data_uri"
      elsif content_bytes && content_type
        @content_bytes = content_bytes.b
        @content_type = content_type
        @source = "bytes"
      elsif file_path && content_type
        @content_bytes = File.binread(file_path)
        @content_type = content_type
        @source = "file"
      end
    end

    def parse_base64_data_uri(data_uri)
      header, encoded = data_uri.delete_prefix("data:").split(",", 2)
      raise ArgumentError, "base64_data_uri must start with data:" unless data_uri.start_with?("data:")
      raise ArgumentError, "base64_data_uri must include ;base64" unless header&.split(";")&.include?("base64")
      raise ArgumentError, "base64_data_uri must include content type" if header.split(";").first.to_s.empty?

      [Base64.strict_decode64(encoded), header.split(";").first]
    rescue ArgumentError
      raise
    rescue StandardError
      raise ArgumentError, "base64_data_uri is invalid"
    end
  end

  LangfuseMedia = Media
end
