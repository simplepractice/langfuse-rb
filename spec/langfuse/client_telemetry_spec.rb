# frozen_string_literal: true

RSpec.describe Langfuse::Client do
  describe "telemetry state" do
    let(:config) do
      Langfuse::Config.new do |candidate|
        candidate.public_key = nil
        candidate.secret_key = nil
        candidate.tracing_enabled = false
      end
    end

    it "constructs without credentials and makes score calls no-ops" do
      client = described_class.new(config)
      WebMock.reset_executed_requests!

      expect(client.create_score(name: nil, value: nil)).to be_nil
      expect(client.create_score!(name: nil, value: nil)).to be_nil
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "defers prompt configuration validation until prompt use" do
      client = described_class.new(config)
      WebMock.reset_executed_requests!

      expect { client.get_prompt("greeting") }.to raise_error(
        Langfuse::ConfigurationError,
        "public_key is required"
      )
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "does not validate unused API credentials during shutdown" do
      client = described_class.new(config)

      expect { client.shutdown }.not_to raise_error
    end

    it "allows prompt access when normal client configuration is valid" do
      config.public_key = "pk_test"
      config.secret_key = "sk_test"
      stub_request(:get, "https://cloud.langfuse.com/api/public/v2/prompts/greeting")
        .to_return(
          status: 200,
          body: { id: "prompt-1", name: "greeting", version: 1, type: "text", prompt: "Hello" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      prompt = described_class.new(config).get_prompt("greeting")

      expect(prompt).to be_a(Langfuse::TextPromptClient)
    end

    it "starts score delivery after telemetry is enabled" do
      config.public_key = "pk_test"
      config.secret_key = "sk_test"
      client = described_class.new(config)
      stub_request(:post, "https://cloud.langfuse.com/api/public/ingestion")
        .to_return(status: 200, body: { successes: [], errors: [] }.to_json)

      config.tracing_enabled = true
      client.create_score(name: "quality", value: 1)
      client.flush_scores

      expect(a_request(:post, "https://cloud.langfuse.com/api/public/ingestion")).to have_been_made.once
    end
  end
end
