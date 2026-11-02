# frozen_string_literal: true

module Sim800c
  module Web
    # GET /api/v1/events: Server-Sent Events, as a plain Rack endpoint (Rails' response buffering
    # and ETag middleware must never see an endless body).
    #
    # Where the server supports a full Rack hijack (Puma, Unicorn, Passenger) the socket is handed to
    # this process's EventHub and no request thread stays busy; otherwise a streaming body writes the
    # frames and holds the request thread for as long as the client stays connected.
    class EventStream
      HEADERS = {
        "content-type" => "text/event-stream; charset=utf-8",
        "cache-control" => "no-cache, no-transform",
        "x-accel-buffering" => "no"
      }.freeze

      # Writes queued frames, for servers without hijack support. Deliberately not array-like.
      class Body
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

      def self.call(env) = new.call(env)

      def call(env)
        request = ActionDispatch::Request.new(env)
        auth = Authenticator.authenticate(request)
        principal = auth.principal
        snapshot = Gateway.snapshot
        hello = { modem: principal.scope?("modem:read") ? snapshot["modem"] : nil,
                  call: principal.scope?("calls:read") ? snapshot["call"] : nil }
        prelude = "retry: 3000\n\n#{EventHub.frame('hello', hello)}"
        scopes = principal.scopes.to_a

        if env["rack.hijack?"] && env["rack.hijack"]
          io = env["rack.hijack"].call
          head = +"HTTP/1.1 200 OK\r\n"
          HEADERS.merge(auth.rate_limit_headers, "connection" => "close").each { |k, v| head << "#{k}: #{v}\r\n" }
          EventHub.instance.add_socket(io, scopes, "#{head}\r\n#{prelude}")
          [200, {}, []]
        else
          [200, HEADERS.merge(auth.rate_limit_headers), Body.new(prelude, EventHub.instance.add_queue(scopes))]
        end
      rescue AppError => e
        error_response(e, e.respond_to?(:headers) ? e.headers : {})
      rescue StandardError => e
        Sim800c.logger.error("[sim800c] Event stream failed: #{e.class}: #{e.message}")
        error_response(AppError.new(500, "internal_error", "Internal server error"))
      end

      private

      def error_response(error, extra_headers = {})
        body = JSON.generate({ error: { code: error.code, message: error.message, details: error.details }.compact })
        [error.status, { "content-type" => "application/json; charset=utf-8" }.merge(extra_headers), [body]]
      end
    end
  end
end
