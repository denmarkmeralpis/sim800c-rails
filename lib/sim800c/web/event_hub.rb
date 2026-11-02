# frozen_string_literal: true

require "set"

module Sim800c
  module Web
    # Fans the runtime's event stream out to this process's Server-Sent Events clients.
    #
    # One upstream RPC subscription per process (opened while there are clients), one hub thread that
    # writes frames with non-blocking writes, sends heartbeats and drops dead or hopelessly slow
    # clients. Clients are either hijacked sockets (no server thread is held) or queues drained by a
    # streaming response body (servers without hijack support).
    class EventHub
      # Bus events forwarded to clients, with the scope needed to receive each.
      STREAMED = {
        "modem.status" => "modem:read",
        "log.entry" => "modem:read",
        "sms.received" => "sms:read",
        "sms.updated" => "sms:read",
        "sms.deleted" => "sms:read",
        "call.updated" => "calls:read",
        "call.incoming" => "calls:read",
        "call.deleted" => "calls:read",
        "ussd.updated" => "calls:read"
      }.freeze
      HEARTBEAT = 25
      MAX_PENDING = 1024 * 1024
      MAX_QUEUED = 2000
      MAX_BACKOFF = 2

      SocketClient = Struct.new(:io, :scopes, :pending)
      QueueClient = Struct.new(:queue, :scopes)
      private_constant :SocketClient, :QueueClient

      @instance_lock = Mutex.new

      class << self
        # The hub of this process (a new one after fork).
        def instance
          @instance_lock.synchronize do
            @instance = nil if @instance_pid != Process.pid
            @instance_pid = Process.pid
            @instance ||= new
          end
        end

        # Formats one SSE frame.
        def frame(name, data) = "event: #{name}\ndata: #{JSON.generate(data)}\n\n"

        # Closes every stream and stops the hub's threads (tests, shutdown).
        def reset!
          hub = @instance_lock.synchronize do
            current = @instance if @instance_pid == Process.pid
            @instance = nil
            current
          end
          hub&.shutdown
        end
      end

      def initialize
        @lock = Mutex.new
        @clients = []
        @events = Thread::Queue.new
        @hub = nil
        @upstream = nil
        @rpc = nil
        # Whether the runtime's stream was up the last time we looked (nil: not known yet).
        @online = nil
        @next_heartbeat = Reactor.now + HEARTBEAT
      end

      def size = @lock.synchronize { @clients.size }

      def shutdown
        clients = @lock.synchronize { @clients.slice!(0..) }
        clients.each { |c| close_client(c) }
        @events << :stop
        @rpc&.unsubscribe
        [@hub, @upstream].compact.each do |thread|
          thread.join(1) || thread.kill
        end
        nil
      end

      # Takes over a hijacked socket. `prelude` (HTTP head, retry and hello frames) is sent first.
      def add_socket(io, scopes, prelude)
        register(SocketClient.new(io, Set.new(scopes), prelude.b))
      end

      # For servers without hijack: returns a Thread::Queue of frames (closed when dropped) to write out.
      def add_queue(scopes)
        queue = Thread::Queue.new
        register(QueueClient.new(queue, Set.new(scopes)))
        queue
      end

      private

      def register(client)
        @lock.synchronize do
          @clients << client
          @hub = start_thread("sim800c-sse-hub") { hub_loop } unless @hub&.alive?
          @upstream = start_thread("sim800c-sse-upstream") { upstream_loop } unless @upstream&.alive?
        end
        @events << :wake
        nil
      end

      def start_thread(name, &block)
        Thread.new do
          Thread.current.name = name
          Thread.current.report_on_exception = false
          block.call
        rescue StandardError => e
          Sim800c.logger.error("[sim800c] #{name} failed: #{e.class}: #{e.message}")
        end
      end

      def no_clients? = @lock.synchronize { @clients.empty? }

      # Keeps one subscription to the runtime while there are clients; reconnects with backoff.
      # Clients are told (with an offline modem status) whenever the runtime stops being reachable.
      def upstream_loop
        backoff = 0.25
        until no_clients?
          begin
            @rpc = Gateway.client
            @rpc.subscribe do |name, data|
              @online = true
              backoff = 0.25
              @events << [name, data]
            end
          rescue StandardError => e
            Sim800c.logger.debug("[sim800c] Event stream from the runtime unavailable: #{e.message}")
          end
          unless @online == false
            @online = false
            @events << :offline
          end
          break if no_clients?

          sleep backoff
          backoff = [backoff * 2, MAX_BACKOFF].min
        end
      ensure
        @rpc = nil
      end

      def hub_loop
        loop do
          clients = @lock.synchronize { @clients.dup }
          pending = clients.any? { |c| c.is_a?(SocketClient) && !c.pending.empty? }
          wait = pending ? 0.05 : [[@next_heartbeat - Reactor.now, 0].max, 1].min
          item = @events.pop(timeout: wait)
          case item
          when :stop then return
          when Array then broadcast(clients, item[0], item[1])
          when :offline then broadcast(clients, "modem.status", Gateway.offline_status(Gateway::NOT_RUNNING))
          end
          clients.each { |c| flush(c) if c.is_a?(SocketClient) }
          reap(clients)
          heartbeat(clients) if Reactor.now >= @next_heartbeat
          next unless no_clients?

          @lock.synchronize do
            next unless @clients.empty?

            @hub = nil
            @rpc&.unsubscribe
            return
          end
        end
      end

      def broadcast(clients, name, data)
        scope = STREAMED[name] or return
        frame = nil
        clients.each do |client|
          next unless client.scopes.include?(scope)

          frame ||= self.class.frame(name, data).b
          deliver(client, frame)
        end
      end

      def heartbeat(clients)
        @next_heartbeat = Reactor.now + HEARTBEAT
        clients.each { |c| deliver(c, ": ping\n\n".b) }
      end

      def deliver(client, bytes)
        if client.is_a?(QueueClient)
          return drop(client) if client.queue.closed? || client.queue.size >= MAX_QUEUED

          client.queue << bytes
        else
          client.pending << bytes
          drop(client) if client.pending.bytesize > MAX_PENDING
        end
      rescue ClosedQueueError
        drop(client)
      end

      def flush(client)
        return if client.pending.empty?

        written = client.io.write_nonblock(client.pending, exception: false)
        client.pending = client.pending.byteslice(written..) if written.is_a?(Integer)
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        drop(client)
      end

      # Drops clients whose connection has closed (readable with EOF) or whose queue was closed.
      def reap(clients)
        clients.each { |c| drop(c) if c.is_a?(QueueClient) && c.queue.closed? }
        sockets = clients.select { |c| c.is_a?(SocketClient) }
        return if sockets.empty?

        by_io = sockets.to_h { |c| [c.io.respond_to?(:to_io) ? c.io.to_io : c.io, c] }
        readable, = IO.select(by_io.keys, nil, nil, 0)
        Array(readable).each do |io|
          client = by_io[io]
          data = client.io.read_nonblock(1024, exception: false)
          drop(client) if data.nil?
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          drop(client)
        end
      rescue IOError, SystemCallError
        sockets.each { |c| drop(c) if c.io.closed? }
      end

      def drop(client)
        removed = @lock.synchronize { @clients.delete(client) }
        close_client(client) if removed
      end

      def close_client(client)
        if client.is_a?(QueueClient)
          client.queue.close
        else
          begin
            client.io.close
          rescue IOError, SystemCallError
            nil
          end
        end
      end
    end
  end
end
