# frozen_string_literal: true

require "socket"
require_relative "io_link"

module Sim800c
  module Transport
    # Talks to a modem exposed over TCP by a serial bridge (`sim800c-bridge`, ser2net, socat...),
    # for a modem plugged into another machine than the one running the gateway.
    class Tcp < Base
      include IoLink

      CONNECT_TIMEOUT = 5

      attr_reader :host, :port

      def initialize(reactor, host, port)
        super(reactor)
        @host = host
        @port = port
        @io = nil
      end

      def description = "tcp://#{host}:#{port}"

      private

      def not_open_message = "Serial bridge connection is not open"

      def connect_io
        socket = Socket.tcp(host, port, connect_timeout: CONNECT_TIMEOUT)
        tune(socket)
        socket
      rescue Errno::ETIMEDOUT, IO::TimeoutError
        raise Error, "Timed out connecting to serial bridge at #{description}"
      rescue SystemCallError, SocketError => e
        raise Error, "Cannot reach serial bridge at #{description}: #{e.message}"
      end

      # No Nagle delay for short AT commands; keepalive probes after 10 s idle to notice a dead peer.
      def tune(socket)
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
        socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
        idle = %i[TCP_KEEPIDLE TCP_KEEPALIVE].find { |name| Socket.const_defined?(name) }
        socket.setsockopt(Socket::IPPROTO_TCP, Socket.const_get(idle), 10) if idle
      rescue SystemCallError
        nil
      end

      def before_close(io)
        io.shutdown(:WR)
      rescue IOError, SystemCallError
        nil
      end

      def closed_error(error)
        error.is_a?(EOFError) ? Error.new("Serial bridge closed the connection") : error
      end
    end
  end
end
