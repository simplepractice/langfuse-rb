# frozen_string_literal: true

RSpec.describe Langfuse::NoopScoreClient do
  subject(:client) { described_class.new }

  it "returns nil for every score lifecycle operation" do
    expect(client.create(name: "quality", value: 1)).to be_nil
    expect(client.create!(name: "quality", value: 1)).to be_nil
    expect(client.score_active_observation(name: "quality", value: 1)).to be_nil
    expect(client.score_active_trace(name: "quality", value: 1)).to be_nil
    expect(client.flush).to be_nil
    expect(client.shutdown).to be_nil
  end
end
