# frozen_string_literal: true

require "socket"

module Sim800c
  module RPC
    # Talks to the runtime from a web process. Thread-safe: every request uses its own connection.
    class Client
      def initialize(url:, token:, connect_timeout: 2)
        @kind, @host, @port = RPC.parse_url(url)
        @url = url
        @token = token.to_s
        @connect_timeout = connect_timeout
      end

      # Returns the operation's result, or raises the AppError the runtime answered with,
      # RPC::Unavailable or RPC::Timeout.
      def request(op, args = {}, timeout: RPC::DEFAULT_TIMEOUT)
        socket = connect
        socket.timeout = timeout + 5
        socket.write("#{JSON.generate({ v: PROTOCOL_VERSION, token: @token, op: op, args: args })}\n")
        line = socket.gets("\n", MAX_LINE)
        raise Unavailable, "the runtime closed the connection" if line.nil?

        response = JSON.parse(line)
        return response["result"] if response["ok"]

        e = response["error"] || {}
        raise AppError.new(e["status"] || 500, e["code"] || "internal_error", e["message"] || "RPC request failed",
                           e["details"])
      rescue IO::TimeoutError
        raise Timeout, "the runtime did not answer #{op} in time"
      rescue JSON::ParserError
        raise Unavailable, "the runtime sent a malformed response"
      rescue IOError, SystemCallError => e
        raise Unavailable, e.message
      ensure
        socket&.close
      end

      # Streams events, yielding (name, data) until the connection ends. Blocks; raises
      # RPC::Unavailable when it cannot connect or the stream breaks.
      def subscribe(heartbeat_timeout: Server::HEARTBEAT * 3)
        socket = connect
        socket.timeout = 10
        socket.write("#{JSON.generate({ v: PROTOCOL_VERSION, token: @token, op: 'subscribe' })}\n")
        ack = JSON.parse(socket.gets("\n", MAX_LINE) || "{}")
        unless ack["ok"]
          raise AppError.new(ack.dig("error", "status") || 500, ack.dig("error", "code") || "internal_error",
                             ack.dig("error", "message") || "Subscription refused")
        end

        socket.timeout = heartbeat_timeout
        @subscription = socket
        while (line = socket.gets("\n", MAX_LINE))
          message = JSON.parse(line)
          next if message["ping"]

          yield message["event"], message["data"]
        end
      rescue IO::TimeoutError
        raise Unavailable, "the event stream went silent"
      rescue JSON::ParserError
        raise Unavailable, "the runtime sent a malformed event"
      rescue IOError, SystemCallError => e
        raise Unavailable, e.message
      ensure
        @subscription = nil
        socket&.close
      end

      # Ends a #subscribe running on another thread.
      def unsubscribe
        @subscription&.close
      rescue IOError, SystemCallError
        nil
      end

      private

      def connect
        if @kind == :unix
          UNIXSocket.new(@host)
        else
          Socket.tcp(@host, @port, connect_timeout: @connect_timeout)
        end
      rescue Errno::ETIMEDOUT, IO::TimeoutError
        raise Unavailable, "timed out connecting to #{@url}"
      rescue SystemCallError, SocketError => e
        raise Unavailable, "cannot connect to #{@url}: #{e.message}"
      rescue ArgumentError => e
        raise Unavailable, "cannot use #{@url}: #{e.message}"
      end
    end
  end
end
