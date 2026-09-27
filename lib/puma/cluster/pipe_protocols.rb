# frozen_string_literal: true

module Puma
  class Cluster
    module PipeProtocols
      module Fork
        @read_buffer = +""
        @write_buffer = []

        PAYLOAD_STRING = "l"
        PAYLOAD_SIZE = 4

        # Returns the value, :wait_readable when the pipe is empty, or nil at end of file.
        # Writes of PAYLOAD_SIZE bytes are atomic, so a read never returns part of a value.
        def self.read_nonblock_from(pipe)
          result = pipe.read_nonblock(PAYLOAD_SIZE, @read_buffer, exception: false)
          result.is_a?(String) ? result.unpack1(PAYLOAD_STRING) : result
        ensure
          @read_buffer.clear
        end

        def self.write_to(pipe, value:)
          @write_buffer << value
          pipe.write(@write_buffer.pack(PAYLOAD_STRING))
        ensure
          @write_buffer.clear
        end
      end
    end
  end
end
