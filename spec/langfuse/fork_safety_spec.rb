# frozen_string_literal: true

RSpec.describe Langfuse::ForkSafety do
  describe ".register" do
    it "runs the registered reset once after each fork" do
      skip "fork is not available" unless Process.respond_to?(:fork)

      resource_class = Class.new do
        attr_reader :reset_pid, :reset_count

        def initialize
          @reset_count = 0
        end

        private

        def reset_after_fork
          @reset_pid = Process.pid
          @reset_count += 1
        end
      end
      resource = resource_class.new
      described_class.register(resource)

      2.times do
        child_pid, status, child_state = capture_forked_state do
          { pid: resource.reset_pid, count: resource.reset_count }
        end

        expect(status).to be_success
        expect(child_state).to eq(pid: child_pid, count: 1)
      end

      expect(resource.reset_count).to eq(0)
    end

    it "installs one process hook for repeated registrations" do
      resource_class = Class.new do
        private

        def reset_after_fork; end
      end
      resources = Array.new(2) { resource_class.new }
      resources.each { |resource| described_class.register(resource) }

      hook_count = Process.singleton_class.ancestors.count do |ancestor|
        ancestor.equal?(described_class::ProcessHook)
      end

      expect(hook_count).to eq(1)
    end
  end
end
