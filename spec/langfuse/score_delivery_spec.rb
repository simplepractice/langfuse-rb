# frozen_string_literal: true

RSpec.describe "Score delivery through the client and HTTP transport" do
  subject(:client) { Langfuse.client }

  let(:url) { "https://cloud.langfuse.com/api/public/scores" }
  let(:headers) { { "Content-Type" => "application/json" } }
  let(:accepted) { { status: 202, body: { message: "Accepted" }.to_json, headers: headers } }
  let(:logger) { instance_double(Logger, debug: nil, info: nil, warn: nil, error: nil) }
  let(:timestamp) { Time.utc(2026, 11, 6, 12) }

  before do
    Langfuse.configure do |config|
      config.public_key = "pk_test"
      config.secret_key = "sk_test"
      config.flush_interval = 3600
      config.batch_size = 10
      config.logger = logger
    end
  end

  after do
    stub_request(:post, url).to_return(accepted)
    client.shutdown
  end

  def queue_score(name)
    client.create_score(name: name, value: 1, id: name, timestamp: timestamp, session_id: "test-session")
  end

  it "removes accepted and permanently rejected scores without retrying either" do
    requests = []
    stub_request(:post, url).to_return do |request|
      names = JSON.parse(request.body).map { |score| score.fetch("name") }
      requests << names
      if names.include?("invalid")
        { status: 207, headers: headers,
          body: { accepted: 1, rejected: 1, errors: [{ message: "Invalid environment" }] }.to_json }
      else
        accepted
      end
    end
    %w[valid invalid later].each { |name| queue_score(name) }
    client.config.batch_size = 2
    expect(logger).to receive(:error).with(/accepted 1 and rejected 1.*Invalid environment/)

    client.flush_scores
    client.flush_scores

    expect(requests).to eq([%w[valid invalid], %w[later]])
    expect(a_request(:post, "https://cloud.langfuse.com/api/public/ingestion")).not_to have_been_made
  end

  [400, 404, 413].each do |status|
    it "discards HTTP #{status} failures and proceeds to the next batch" do
      request = stub_request(:post, url).to_return(
        { status: status, body: { message: "Invalid request" }.to_json, headers: headers }, accepted
      )
      %w[invalid valid].each { |name| queue_score(name) }
      client.config.batch_size = 1

      client.flush_scores
      client.flush_scores

      expect(request).to have_been_requested.twice
      expect(logger).to have_received(:error).with(/permanent batch failure.*#{status}/)
    end
  end

  it "retains scores after authentication errors and retries with unchanged bodies" do
    bodies = []
    stub_request(:post, url).to_return do |request|
      bodies << request.body
      bodies.length == 1 ? { status: 401 } : accepted
    end
    queue_score("quality")

    client.flush_scores
    client.flush_scores
    client.flush_scores

    expect(bodies.size).to eq(2)
    expect(bodies.uniq.size).to eq(1)
  end

  it "preserves IDs, timestamps and queue order after transient retries are exhausted" do
    bodies = []
    stub_request(:post, url).to_return do |request|
      bodies << JSON.parse(request.body)
      bodies.length <= 3 ? { status: 503 } : accepted
    end
    queue_score("first")
    client.flush_scores
    expect(bodies.length).to eq(3)
    queue_score("later")
    client.flush_scores

    expect(bodies.first(3).uniq.size).to eq(1)
    expect(bodies.last.first).to eq(bodies.first.first)
    expect(bodies.last.map { |score| score.fetch("id") }).to eq(%w[first later])
    expect(bodies.last.map { |score| score.fetch("timestamp") }.uniq).to eq([timestamp.iso8601(3)])
  end

  it "retries rate limiting within the request without changing score identity" do
    request = stub_request(:post, url).with do |req|
      score = JSON.parse(req.body).first
      score.values_at("id", "timestamp") == ["quality", timestamp.iso8601(3)]
    end
    request.to_return({ status: 429 }, accepted)

    expect(client.create_score!(id: "quality", timestamp: timestamp, name: "quality", value: 1)).to eq("quality")
    expect(request).to have_been_requested.twice
  end

  it "retains scores after an ambiguous network failure and delivers them on the next flush" do
    request = stub_request(:post, url).to_timeout
    queue_score("quality")
    client.flush_scores
    expect(request).to have_been_requested.times(3)
    delivered = []
    stub_request(:post, url).to_return do |req|
      delivered << JSON.parse(req.body)
      accepted
    end

    client.flush_scores
    client.shutdown

    expect(delivered).to match([[hash_including("id" => "quality", "timestamp" => timestamp.iso8601(3))]])
  end

  it "does not discard scores when the server returns an unrecognized acceptance body" do
    request = stub_request(:post, url).to_return({ status: 202, body: "{}", headers: headers }, accepted)
    queue_score("quality")
    client.flush_scores
    client.flush_scores

    expect(request).to have_been_requested.twice
  end

  it "keeps capacity reserved during HTTP delivery and preserves concurrently queued scores" do
    Langfuse.configuration.score_queue_capacity = 2
    started = Queue.new
    release = Queue.new
    batches = []
    stub_request(:post, url).to_return do |request|
      batches << JSON.parse(request.body).map { |score| score.fetch("name") }
      if batches.length == 1
        started << true
        release.pop
      end
      accepted
    end
    queue_score("first")
    worker = Thread.new { client.flush_scores }
    started.pop
    queue_score("second")
    queue_score("overflow")
    release << true
    worker.join

    expect(batches).to eq([%w[first], %w[second]])
    expect(logger).to have_received(:error).with(/queue is full/)
  ensure
    release&.push(true)
    worker&.join
  end
end
