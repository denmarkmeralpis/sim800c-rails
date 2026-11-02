# frozen_string_literal: true

require "set"

module Sim800c
  module Web
    # Fans the runtime's event stream out to this process's Server-Sent Events clients.
    #
    # * One upstream RPC subscription per process, held while there are clients. The runtime starts
    #   it with a snapshot (modem status and current call) and the hub keeps that state current from
    #   the events, so a new client's hello is taken atomically with its registration.
    # * One hub thread writes frames with non-blocking writes, sends heartbeats and drops dead or
    #   hopelessly slow clients.
    # * Clients are hijacked sockets (no server thread is held) or queues drained by a streaming
    #   response body (servers without hijack support).
    # * Each thread clears its own slot under the lock when it exits; #register starts what is missing
    #   under the same lock.
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
      ACTIVE_CALL = %w[dialing ringing active].freeze
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

        # Closes every stream and stops the hub's threads (tests, shutdown).
        def reset!
          hub = @instance_lock.synchronize do
            current = @instance if @instance_pid == Process.pid
            @instance = nil
            current
          end
          hub&.shutdown
        end

        # Formats one SSE frame.
        def frame(name, data) = "event: #{name}\ndata: #{JSON.generate(data)}\n\n"
      end

      def initialize
        @lock = Mutex.new
        @clients = []
        @events = Thread::Queue.new
        @hub = nil
        @upstream = nil
        @rpc = nil
        # {"modem" => status, "call" => call or nil} while the runtime's stream is up; nil when unknown.
        @state = nil
        @online = nil # whether the stream was up the last time we looked (nil: not known yet)
        @next_heartbeat = Reactor.now + HEARTBEAT
      end

      def size = @lock.synchronize { @clients.size }

      # True while the hub knows the runtime's current state (a hello needs no RPC then).
      def warm? = @lock.synchronize { !@state.nil? }

      # Takes over a hijacked socket. `head` (HTTP status line and headers) is written first, then
      # `retry` and the hello. `fallback` ({"modem", "call"}) is used for the hello while the hub has
      # no state of its own yet.
      def add_socket(io, scopes, head, fallback = nil)
        scopes = Set.new(scopes)
        register(scopes, fallback) { |hello| SocketClient.new(io, scopes, "#{head}#{hello}".b) }
      end

      # For servers without hijack support: returns a Thread::Queue of frames, starting with the
      # hello, to write out (closed when the client is dropped).
      def add_queue(scopes, fallback = nil)
        scopes = Set.new(scopes)
        queue = Thread::Queue.new
        register(scopes, fallback) do |hello|
          queue << hello
          QueueClient.new(queue, scopes)
        end
        queue
      end

      def shutdown
        clients = @lock.synchronize { @clients.slice!(0..) }
        clients.each { |c| close_client(c) }
        @events << :stop
        @rpc&.unsubscribe
        [@hub, @upstream].compact.each { |thread| thread.join(1) || thread.kill }
        nil
      end

      private

      def register(scopes, fallback = nil)
        @lock.synchronize do
          state = @state || fallback || offline_state
          hello = { modem: scopes.include?("modem:read") ? state["modem"] : nil,
                    call: scopes.include?("calls:read") ? state["call"] : nil }
          @clients << yield("retry: 3000\n\n#{self.class.frame('hello', hello)}")
          @hub = start_thread("sim800c-sse-hub") { hub_loop } unless @hub&.alive?
          @upstream = start_thread("sim800c-sse-upstream") { upstream_loop } unless @upstream&.alive?
        end
        @events << :wake
        nil
      end

      def offline_state = { "modem" => Gateway.offline_status(Gateway::NOT_RUNNING), "call" => nil }

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
        loop do
          leaving = @lock.synchronize do
            next false unless @clients.empty?

            @upstream = nil
            @state = nil
            @online = nil
            true
          end
          break if leaving

          rpc = @rpc = Gateway.client
          begin
            rpc.subscribe do |name, data|
              if no_clients?
                rpc.unsubscribe # nobody left to tell; the loop exits above
                next
              end
              @online = true
              backoff = 0.25
              @events << [name, data]
            end
          rescue StandardError => e
            Sim800c.logger.debug("[sim800c] Event stream from the runtime unavailable: #{e.message}")
          end
          next if no_clients?

          unless @online == false
            @online = false
            @events << :offline
          end
          sleep backoff
          backoff = [backoff * 2, MAX_BACKOFF].min
        end
      end

      def hub_loop
        loop do
          clients = @lock.synchronize { @clients.dup }
          pending = clients.any? { |c| c.is_a?(SocketClient) && !c.pending.empty? }
          wait = pending ? 0.05 : [[@next_heartbeat - Reactor.now, 0].max, 1].min
          case (item = @events.pop(timeout: wait))
          when :stop then return
          when :offline then publish("offline", nil)
          when Array then publish(item[0], item[1])
          end
          clients = @lock.synchronize { @clients.dup }
          clients.each { |c| flush(c) if c.is_a?(SocketClient) }
          reap(clients)
          heartbeat(clients) if Reactor.now >= @next_heartbeat

          @lock.synchronize do
            next unless @clients.empty?

            @hub = nil
            @rpc&.unsubscribe
            return
          end
        end
      end

      # Updates the state and broadcasts to the clients registered at that moment, atomically with
      # respect to #register.
      def publish(name, data)
        frames = []
        clients = @lock.synchronize do
          case name
          when "snapshot"
            @state = { "modem" => data["modem"], "call" => data["call"] }
            frames << ["modem.status", data["modem"]]
            frames << ["call.updated", data["call"]] if data["call"]
          when "offline"
            @state = offline_state
            frames << ["modem.status", @state["modem"]]
          else
            track(name, data)
            frames << [name, data]
          end
          @clients.dup
        end
        frames.each { |n, d| broadcast(clients, n, d) }
      end

      def track(name, data)
        return unless @state

        case name
        when "modem.status" then @state["modem"] = data
        when "call.updated", "call.incoming"
          if ACTIVE_CALL.include?(data["status"])
            @state["call"] = data
          elsif @state["call"]&.dig("id") == data["id"]
            @state["call"] = nil
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
          drop(client) if client.io.read_nonblock(1024, exception: false).nil?
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
