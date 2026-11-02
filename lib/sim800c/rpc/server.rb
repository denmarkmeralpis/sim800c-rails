# frozen_string_literal: true

require "socket"
require "fileutils"

module Sim800c
  module RPC
    # Accepts RPC connections in the runtime. Each connection gets a thread; requests are handed to
    # the handler (Runtime::Operations), which runs them on the reactor.
    class Server
      MAX_CONNECTIONS = 128
      READ_TIMEOUT = 30
      HEARTBEAT = 15
      MAX_BACKLOG = 10_000

      attr_reader :url

      def initialize(url:, token:, handler:, logger: Sim800c.logger)
        @url = url
        @token = token.to_s
        @handler = handler
        @logger = logger
        @connections = Set.new
        @lock = Mutex.new
        @stopping = false
        @wake_reader, @wake_writer = IO.pipe
      end

      def description
        kind, host, port = RPC.parse_url(@url)
        kind == :unix ? "unix://#{host}" : "tcp://#{host}:#{@port || port}"
      end

      # The TCP port actually bound (useful with port 0), or nil for a Unix socket.
      attr_reader :port

      def start
        kind, host, port = RPC.parse_url(@url)
        if kind == :unix
          @path = host
          @server = listen_unix(host)
        else
          @server = TCPServer.new(host, port)
          @port = @server.local_address.ip_port
        end
        @accept_thread = Thread.new do
          Thread.current.name = "sim800c-rpc-accept"
          accept_loop
        end
        self
      end

      # Stops accepting, answers clients still waiting in the listen queue with a 503, and closes every
      # connection. The listener is closed by this thread only after the acceptor has exited: closing
      # it under a thread blocked in accept(2) can strand a queued client with no answer at all.
      def stop
        @stopping = true
        @wake_writer.write_nonblock(".", exception: false)
        @accept_thread&.join(2)
        begin
          File.unlink(@path) if @path && File.socket?(@path) # no new clients from here on
        rescue SystemCallError
          nil
        end
        if @server
          stopping = AppError.modem_unavailable("Gateway runtime is shutting down")
          while (socket = @server.accept_nonblock(exception: false)).is_a?(BasicSocket)
            reject(socket, stopping)
          end
          @server.close
        end
        sockets = @lock.synchronize { @connections.to_a }
        sockets.each { |s| close_quietly(s) }
        nil
      rescue IOError, SystemCallError
        nil
      ensure
        close_quietly(@wake_reader)
        close_quietly(@wake_writer)
      end

      private

      def listen_unix(path)
        RPC.secure_socket_dir!(path)
        FileUtils.mkdir_p(File.dirname(path))
        if File.exist?(path)
          raise Error, "Another sim800c runtime is listening on #{path}" if socket_alive?(path)

          File.unlink(path)
        end
        server = UNIXServer.new(path)
        File.chmod(0o600, path)
        server
      rescue ArgumentError => e
        raise ConfigError, "Cannot use #{path} for the RPC socket (#{e.message}); set config.rpc.url to a shorter path"
      end

      def socket_alive?(path)
        UNIXSocket.new(path).close
        true
      rescue SystemCallError
        false
      end

      def accept_loop
        loop do
          IO.select([@server, @wake_reader])
          break if @stopping

          socket = @server.accept_nonblock(exception: false)
          next unless socket.is_a?(BasicSocket)

          if @lock.synchronize { @connections.size } >= MAX_CONNECTIONS
            reject(socket, AppError.new(503, "busy", "Too many RPC connections"))
            next
          end
          @lock.synchronize { @connections << socket }
          Thread.new(socket) do |s|
            Thread.current.name = "sim800c-rpc"
            Thread.current.report_on_exception = false
            handle(s)
          end
        rescue IOError, Errno::EBADF
          break
        rescue SystemCallError => e
          break if @stopping

          @logger.warn("[sim800c] RPC accept failed: #{e.message}")
          sleep 0.05
        end
      end

      def handle(socket)
        socket.timeout = READ_TIMEOUT
        line = socket.gets("\n", MAX_LINE)
        return if line.nil?

        request = begin
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
        unless request.is_a?(Hash)
          return write_line(socket, error_payload(AppError.bad_request("Malformed RPC request")))
        end
        unless OpenSSL.secure_compare(request["token"].to_s, @token)
          return write_line(socket, error_payload(AppError.new(401, "unauthorized", "Invalid RPC token")))
        end

        op = request["op"].to_s
        args = request["args"].is_a?(Hash) ? request["args"] : {}
        if op == "subscribe"
          stream(socket)
        else
          write_line(socket, @handler.dispatch(op, args))
        end
      rescue IOError, SystemCallError, IO::TimeoutError
        nil
      rescue StandardError => e
        @logger.error("[sim800c] RPC connection failed: #{e.class}: #{e.message}")
      ensure
        @lock.synchronize { @connections.delete(socket) }
        close_quietly(socket)
      end

      # Streams bus events until the client goes away or falls too far behind.
      def stream(socket)
        queue = Thread::Queue.new
        overflow = false
        unsubscribe = @handler.subscribe do |name, data|
          if queue.size >= MAX_BACKLOG
            overflow = true
            queue.close
          else
            queue << [name, data]
          end
        rescue ClosedQueueError
          nil
        end
        write_line(socket, { ok: true })
        # Notice right away when the client goes away (it never sends anything after subscribing).
        watcher = Thread.new do
          Thread.current.report_on_exception = false
          socket.timeout = nil
          socket.read
        rescue IOError, SystemCallError
          nil
        ensure
          queue.close
        end
        until overflow
          item = queue.pop(timeout: HEARTBEAT)
          break if item.nil? && queue.closed?

          write_line(socket, item ? { event: item[0], data: item[1] } : { ping: true })
        end
        @logger.warn("[sim800c] Dropped a slow event subscriber") if overflow
      ensure
        unsubscribe&.call
        queue&.close
        watcher&.kill
      end

      def error_payload(error) = { ok: false, error: error.to_h }

      def reject(socket, error)
        write_line(socket, error_payload(error))
      rescue IOError, SystemCallError
        nil
      ensure
        close_quietly(socket)
      end

      def write_line(socket, payload)
        socket.write("#{JSON.generate(payload)}\n")
      end

      def close_quietly(socket)
        socket.close
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
