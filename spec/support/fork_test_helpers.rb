# frozen_string_literal: true

module ForkTestHelpers
  def capture_forked_state
    reader, writer = IO.pipe
    child_pid = Process.fork do
      reader.close
      writer.write(Marshal.dump(yield))
      writer.close
      exit!(0)
    end
    writer.close
    child_state = Marshal.load(reader.read) # rubocop:disable Security/MarshalLoad
    _, status = Process.wait2(child_pid)
    [child_pid, status, child_state]
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end
end
