# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::ExitHook do
  after do
    described_class.enable
  end

  describe ".install!" do
    it "registers one process callback" do
      installed = described_class.instance_variable_get(:@installed)
      described_class.instance_variable_set(:@installed, false)
      allow(Kernel).to receive(:at_exit)

      described_class.install!
      described_class.install!

      expect(Kernel).to have_received(:at_exit).once
    ensure
      described_class.instance_variable_set(:@installed, installed)
    end
  end

  describe ".run" do
    it "runs shutdown once" do
      described_class.enable
      expect(Langfuse).to receive(:shutdown).once

      described_class.run
      described_class.run
    end

    it "warns without raising when shutdown fails" do
      described_class.enable
      allow(Langfuse).to receive(:shutdown).and_raise(Langfuse::ApiError, "unavailable")
      expect(Kernel).to receive(:warn).with(/Langfuse exit flush failed: Langfuse::ApiError - unavailable/)

      expect { described_class.run }.not_to raise_error
    end
  end

  describe "fork safety" do
    it "replaces the inherited hook mutex in a forked child" do
      skip "fork is not available" unless Process.respond_to?(:fork)

      parent_mutex = described_class.send(:mutex)
      _child_pid, status, child_state = capture_forked_state do
        { mutex_replaced: !described_class.send(:mutex).equal?(parent_mutex) }
      end

      expect(status).to be_success
      expect(child_state).to eq(mutex_replaced: true)
      expect(described_class.send(:mutex)).to equal(parent_mutex)
    end
  end
end
