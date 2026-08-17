# frozen_string_literal: true

module ForkTestHelpers
  FORK_WAIT_SECONDS = 5
  private_constant :FORK_WAIT_SECONDS

  def capture_forked_state
    reader, writer = IO.pipe
    child_pid = Process.fork do
      reader.close
      writer.write(Marshal.dump(yield))
      writer.close
    end
    writer.close
    payload = read_child_payload(reader)
    completed_child_pid, status = Process.wait2(child_pid)
    child_pid = nil
    child_state = payload.empty? ? nil : Marshal.load(payload) # rubocop:disable Security/MarshalLoad
    [completed_child_pid, status, child_state]
  ensure
    terminate_child(child_pid)
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  private

  def read_child_payload(reader)
    unless reader.wait_readable(FORK_WAIT_SECONDS)
      raise "forked child did not respond within #{FORK_WAIT_SECONDS} seconds"
    end

    reader.read
  end

  def terminate_child(child_pid)
    return unless child_pid

    ignore_missing_process { Process.kill("KILL", child_pid) }
    ignore_missing_process { Process.wait(child_pid) }
  end

  def ignore_missing_process
    yield
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end
end
