# frozen_string_literal: true

RSpec.describe Langfuse::PendingScoreQueue do
  subject(:queue) { described_class.new(capacity: 2) }

  it "accepts events up to its capacity without mutating the input snapshot" do
    expect(queue.push({ id: 1 })).to be true
    snapshot = queue.snapshot
    expect(queue.push({ id: 2 })).to be true

    expect(snapshot).to eq([{ id: 1 }])
    expect(queue.size).to eq(2)
  end

  it "rejects a new event when full" do
    queue.push({ id: 1 })
    queue.push({ id: 2 })

    expect(queue.push({ id: 3 })).to be false
    expect(queue.snapshot).to eq([{ id: 1 }, { id: 2 }])
  end

  it "removes only a delivered prefix" do
    queue.push({ id: 1 })
    queue.push({ id: 2 })

    queue.remove_prefix(1)

    expect(queue.snapshot).to eq([{ id: 2 }])
    expect(queue).not_to be_empty
  end

  it "returns a stable limited prefix" do
    queue.push({ id: 1 })
    queue.push({ id: 2 })

    prefix = queue.first(1)
    queue.remove_prefix(1)

    expect(prefix).to eq([{ id: 1 }])
    expect(queue.snapshot).to eq([{ id: 2 }])
  end
end
