# frozen_string_literal: true

RSpec.describe Langfuse::DeferredApiClient do
  subject(:client) { described_class.new { api_client } }

  let(:api_client) { instance_double(Langfuse::ApiClient, list_prompts: ["prompt"], shutdown: nil) }

  it "does not build the API client for unused shutdown" do
    factory_calls = 0
    deferred = described_class.new do
      factory_calls += 1
      api_client
    end

    deferred.shutdown

    expect(factory_calls).to eq(0)
  end

  it "builds the API client once when an API method is used" do
    expect(client.list_prompts).to eq(["prompt"])
    expect(client.list_prompts).to eq(["prompt"])
  end

  it "reports the API client method surface" do
    expect(client).to respond_to(:list_prompts)
    expect(client).not_to respond_to(:unknown_operation)
  end

  it "shuts down an API client after it is built" do
    client.list_prompts

    expect(api_client).to receive(:shutdown)
    client.shutdown
  end
end
