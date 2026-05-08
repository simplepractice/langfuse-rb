# frozen_string_literal: true

RSpec.describe Langfuse::Media do
  let(:base_url) { "https://cloud.langfuse.com" }
  let(:config) do
    Langfuse::Config.new do |c|
      c.public_key = "pk_test_123"
      c.secret_key = "sk_test_456"
      c.base_url = base_url
    end
  end
  let(:client) { Langfuse::Client.new(config) }

  describe "#initialize" do
    it "wraps raw bytes and builds deterministic media metadata" do
      media = described_class.new(content_bytes: "hello", content_type: "text/plain")

      expect(media.source).to eq("bytes")
      expect(media.content_length).to eq(5)
      expect(media.media_id).to eq("LPJNul-wow4m6Dsqxbninh")
      expect(media.reference_string).to eq(
        "@@@langfuseMedia:type=text/plain|id=LPJNul-wow4m6Dsqxbninh|source=bytes@@@"
      )
      expect(media.base64_data_uri).to eq("data:text/plain;base64,aGVsbG8=")
    end

    it "parses base64 data URIs" do
      media = described_class.new(base64_data_uri: "data:text/plain;base64,aGVsbG8=")

      expect(media.content_bytes).to eq("hello")
      expect(media.content_type).to eq("text/plain")
      expect(media.source).to eq("base64_data_uri")
    end

    it "raises for invalid media input" do
      expect { described_class.new(content_bytes: "hello") }
        .to raise_error(ArgumentError, "media content and content_type are required")
    end
  end

  describe ".parse_reference_string" do
    it "parses Langfuse media reference tokens" do
      reference = described_class.parse_reference_string(
        "@@@langfuseMedia:type=image/png|id=media-123|source=bytes@@@"
      )

      expect(reference.media_id).to eq("media-123")
      expect(reference.content_type).to eq("image/png")
      expect(reference.source).to eq("bytes")
    end

    it "raises on malformed tokens" do
      expect { described_class.parse_reference_string("@@@bad@@@") }
        .to raise_error(ArgumentError, /does not start/)
    end
  end

  describe ".resolve_references" do
    let(:reference_string) { "@@@langfuseMedia:type=text/plain|id=media-123|source=bytes@@@" }
    let(:download_url) { "https://media.langfuse.test/media-123" }

    before do
      stub_request(:get, "#{base_url}/api/public/media/media-123")
        .to_return(status: 200, body: {
          mediaId: "media-123",
          contentType: "text/plain",
          url: download_url
        }.to_json, headers: { "Content-Type" => "application/json" })
      stub_request(:get, download_url)
        .to_return(status: 200, body: "hello")
    end

    it "replaces nested media references with base64 data URIs" do
      obj = { "input" => ["before #{reference_string} after"] }

      result = described_class.resolve_references(obj, client: client)

      expect(result).to eq({ "input" => ["before data:text/plain;base64,aGVsbG8= after"] })
      expect(obj).to eq({ "input" => ["before #{reference_string} after"] })
    end

    it "leaves unresolved references intact" do
      stub_request(:get, download_url).to_return(status: 500, body: "nope")
      obj = { "input" => reference_string }

      result = described_class.resolve_references(obj, client: client)

      expect(result).to eq(obj)
    end
  end
end
