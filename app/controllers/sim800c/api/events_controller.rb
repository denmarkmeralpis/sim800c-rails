# frozen_string_literal: true

module Sim800c
  module Api
    # GET /events: Server-Sent Events. The connection is handed to this process's EventHub (a full
    # Rack hijack where the server supports it, so no request thread stays busy).
    class EventsController < ApiController
      HEADERS = {
        "content-type" => "text/event-stream; charset=utf-8",
        "cache-control" => "no-cache, no-transform",
        "x-accel-buffering" => "no"
      }.freeze

      # Writes queued frames for servers without hijack support (holds the request thread).
      class QueueBody
        def initialize(prelude, queue)
          @prelude = prelude
          @queue = queue
        end

        def each
          yield @prelude
          while (frame = @queue.pop)
            yield frame
          end
        end

        def close = @queue.close
      end

      before_action :authenticate!

      def stream
        scopes = principal.scopes.to_a
        snapshot = Gateway.snapshot
        hello = { modem: principal.scope?("modem:read") ? snapshot["modem"] : nil,
                  call: principal.scope?("calls:read") ? snapshot["call"] : nil }
        prelude = "retry: 3000\n\n#{Web::EventHub.frame('hello', hello)}"

        if request.env["rack.hijack?"] && request.env["rack.hijack"]
          io = request.env["rack.hijack"].call
          head = +"HTTP/1.1 200 OK\r\n"
          HEADERS.merge("connection" => "close").each { |name, value| head << "#{name}: #{value}\r\n" }
          Web::EventHub.instance.add_socket(io, scopes, "#{head}\r\n#{prelude}")
          self.response_body = []
        else
          HEADERS.each { |name, value| response.set_header(name, value) }
          self.response_body = QueueBody.new(prelude, Web::EventHub.instance.add_queue(scopes))
        end
      end
    end
  end
end
