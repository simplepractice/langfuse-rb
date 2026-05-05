# frozen_string_literal: true

require "spec_helper"

RSpec.describe "langfuse rake cache contract" do
  let(:rake_source) { File.read(File.expand_path("../../lib/tasks/langfuse.rake", __dir__)) }

  it "uses public SDK cache APIs" do
    expect(rake_source).not_to include("Langfuse.client.api_client.cache")
    expect(rake_source).to include("Langfuse.client.clear_prompt_cache")
    expect(rake_source).to include("Langfuse::CacheWarmer.new")
  end
end
