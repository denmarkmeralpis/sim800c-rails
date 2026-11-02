# frozen_string_literal: true

require_relative "io_link"

module Sim800c
  module Transport
    # A modem on a local serial port (USB adapter or UART), 8N1, no flow control.
    #
    # The device is opened non-blocking without becoming the controlling terminal, locked with
    # flock (like node-serialport, so two gateways cannot fight over it) and configured by running
    # `stty` against the open descriptor, which keeps the settings for as long as it stays open.
    # Linux and macOS.
    class Serial < Base
      include IoLink

      STTY_FLAGS = %w[raw -echo cs8 -cstopb -parenb -crtscts -ixon -ixoff clocal cread].freeze
      PATTERNS = %w[/dev/ttyUSB* /dev/ttyACM* /dev/ttyAMA* /dev/ttyS[0-9]* /dev/serial/by-id/* /dev/cu.*].freeze

      attr_reader :path, :baud_rate

      # Serial devices present on this machine (by-id links resolve to stable names on Linux).
      def self.list
        PATTERNS.flat_map { |pattern| Dir.glob(pattern) }.uniq.sort.map do |path|
          { path: path, target: File.symlink?(path) ? File.realpath(path) : nil }
        rescue SystemCallError
          { path: path, target: nil }
        end
      end

      def initialize(reactor, path, baud_rate)
        super(reactor)
        @path = path
        @baud_rate = baud_rate
        @io = nil
      end

      def description = "#{path} @ #{baud_rate} baud"

      private

      def not_open_message = "Serial port is not open"

      def connect_io
        io = File.new(path, File::RDWR | File::NOCTTY | File::NONBLOCK | File::BINARY)
        begin
          unless io.flock(File::LOCK_EX | File::LOCK_NB)
            raise Error, "Cannot open #{path}: another program is using the serial port"
          end

          configure(io)
        rescue StandardError
          io.close
          raise
        end
        io.sync = true
        io
      rescue Errno::ENOENT
        raise Error, "Cannot open #{path}: no such device (is the modem plugged in?)"
      rescue Errno::EACCES
        raise Error, "Cannot open #{path}: permission denied (on Linux, add the user to the dialout group)"
      rescue Errno::EBUSY
        raise Error, "Cannot open #{path}: resource busy (another program is using the serial port)"
      end

      def configure(io)
        output = IO.popen(["stty", baud_rate.to_s, *STTY_FLAGS], in: io, err: %i[child out], &:read)
        return if $?.success?

        raise Error, "Cannot configure #{path} at #{baud_rate} baud: #{output.strip}"
      rescue Errno::ENOENT
        raise Error, "Cannot configure #{path}: the stty command was not found (install coreutils)"
      end
    end
  end
end
