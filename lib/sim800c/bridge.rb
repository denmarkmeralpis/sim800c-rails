# frozen_string_literal: true

require "socket"

module Sim800c
  # Exposes a modem transport as a raw TCP byte stream for one client at a time, for a gateway that
  # cannot open the modem itself (it runs on another machine, or in a container without the USB
  # device). The newest client wins. When the serial side drops, the client is disconnected so the
  # gateway notices and goes through its normal reconnect path; the port is reopened every
  # `reopen` seconds until the modem is back.
  #
  # There is no authentication: anyone who can connect controls the modem.
  class Bridge
    # One TCP client, with its own reader and writer threads.
    class Client
      attr_reader :peer

      def initialize(socket, reactor)
        @socket = socket
        @reactor = reactor
        @queue = Thread::Queue.new
        @peer = begin
          socket.remote_address.inspect_sockaddr
        rescue StandardError
          "unknown"
        end
      end

      # Starts the threads. `on_data` and `on_close` run on the reactor thread.
      def start(on_data:, on_close:)
        @socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
        @socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, true)
        Thread.new do
          Thread.current.report_on_exception = false
          loop do
            chunk = @socket.readpartial(4096)
            @reactor.post { on_data.call(chunk) }
          end
        rescue EOFError, IOError, SystemCallError
          @reactor.post { on_close.call }
        end
        Thread.new do
          Thread.current.report_on_exception = false
          while (chunk = @queue.pop)
            @socket.write(chunk)
          end
        rescue IOError, SystemCallError
          close
        end
        self
      end

      def write(chunk)
        @queue << chunk
      rescue ClosedQueueError
        nil
      end

      def close
        @queue.close
        @socket.close
      rescue IOError, SystemCallError
        nil
      end
    end

    attr_reader :host, :port

    def self.start(transport, host: "127.0.0.1", port: 7070, reopen: 2, logger: Sim800c.logger)
      new(transport, host: host, port: port, reopen: reopen, logger: logger).start
    end

    def initialize(transport, host:, port:, reopen:, logger:)
      @transport = transport
      @reactor = transport.reactor
      @host = host
      @port = port
      @reopen = reopen
      @logger = logger
      @client = nil
      @stopped = false
      @reopen_timer = nil
      @last_open_error = nil
    end

    # Listens, then tries to open the serial port once. Call from outside the reactor (or a task).
    def start
      @server = TCPServer.new(@host, @port)
      @port = @server.local_address.ip_port
      @reactor.call do
        wire_transport
        open_serial
      end
      @accept_thread = Thread.new { accept_loop }
      self
    end

    def close
      @reactor.call do
        @stopped = true
        @reopen_timer&.cancel
        drop_client
        begin
          @reactor.await(@transport.close)
        rescue StandardError
          nil
        end
      end
      @server&.close
      @accept_thread&.join(2)
      nil
    end

    private

    def wire_transport
      @transport.on(:data) { |chunk| @client&.write(chunk) }
      @transport.on(:error) { |e| @logger.warn("[sim800c-bridge] Serial port error: #{e.message}") }
      @transport.on(:close) do |error|
        @logger.warn("[sim800c-bridge] Serial port closed#{": #{error.message}" if error}")
        drop_client
        unless @stopped
          @reopen_timer&.cancel
          @reopen_timer = @reactor.after(@reopen) { open_serial }
        end
      end
    end

    def open_serial
      return if @stopped || @transport.open?

      @reactor.await(@transport.open)
      @last_open_error = nil
      @logger.info("[sim800c-bridge] Serial port open: #{@transport.description}")
    rescue StandardError => e
      if e.message != @last_open_error
        @logger.warn("[sim800c-bridge] Cannot open #{@transport.description}, retrying: #{e.message}")
      end
      @last_open_error = e.message
      @reopen_timer = @reactor.after(@reopen) { open_serial } unless @stopped
    end

    def accept_loop
      loop do
        socket = @server.accept
        @reactor.post { on_client(socket) }
      rescue IOError, Errno::EBADF
        break
      rescue SystemCallError => e
        @logger.warn("[sim800c-bridge] accept failed: #{e.message}")
        sleep 0.1
      end
    end

    def on_client(socket)
      client = Client.new(socket, @reactor)
      if @stopped || !@transport.open?
        @logger.warn("[sim800c-bridge] Rejecting client #{client.peer}: serial port is not open")
        client.close
        return
      end
      if @client
        @logger.info("[sim800c-bridge] New client connected, dropping the previous one")
        @client.close
      end
      @client = client
      @logger.info("[sim800c-bridge] Client connected: #{client.peer}")
      client.start(
        on_data: lambda { |chunk|
          next unless @client.equal?(client)

          @transport.write(chunk).on_settle do |w|
            @logger.warn("[sim800c-bridge] Serial write failed: #{w.reason.message}") if w.rejected?
          end
        },
        on_close: lambda {
          @client = nil if @client.equal?(client)
          client.close
          @logger.info("[sim800c-bridge] Client disconnected: #{client.peer}")
        }
      )
    end

    def drop_client
      @client&.close
      @client = nil
    end
  end
end
