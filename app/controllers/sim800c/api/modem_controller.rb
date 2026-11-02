# frozen_string_literal: true

module Sim800c
  module Api
    class ModemController < ApiController
      # Commands that would desynchronise the driver from the modem's configuration.
      BLOCKED_AT = [
        [/\AATE/i, "echo is managed by the driver"],
        [/\AAT\+IPR/i, "changing the baud rate would break the serial link"],
        [/\AAT\+(CMGF|CNMI|CMEE|CPMS|CSCS)=/i, "SMS/error reporting mode is managed by the driver"],
        [/\AAT\+CMGS/i, "use the SMS API to send messages"]
      ].freeze

      before_action :authenticate!

      def show
        require_scope!("modem:read")
        snapshot = Gateway.snapshot
        render json: { data: snapshot["modem"], canOperate: snapshot["canOperate"], reason: snapshot["reason"] }
      end

      def signal
        require_scope!("modem:read")
        render json: { data: offline_fallback([]) { Gateway.request("modem.signal") } }
      end

      def events
        require_scope!("modem:read")
        v = query_validation
        options = {
          limit: v.integer("limit", min: 1, max: 500, default: 100),
          level: v.enum("level", EventLogEntry::LEVELS),
          category: v.string("category", max: 40, optional: true),
          before: v.integer("before", min: 1, optional: true)
        }
        v.validate!
        render json: { data: EventLogEntry.recent(**options).map(&:as_api) }
      end

      def refresh
        require_scope!("modem:read")
        render json: { data: Gateway.request("modem.refresh") }
      end

      def reconnect
        require_scope!("modem:write")
        render json: { data: Gateway.request("modem.reconnect", { reason: "Manual reconnect by #{principal.name}" }) },
               status: :accepted
      end

      def restart
        require_scope!("modem:write")
        render json: { data: Gateway.request("modem.restart") }, status: :accepted
      end

      # The AT console: admins only, from the dashboard.
      def at
        require_scope!("admin")
        require_session!
        v = body_validation
        command = v.string("command", trim: true, min: 2, max: 200, format: /\AAT/i,
                                      format_message: "Command must start with AT")
        timeout_ms = v.integer("timeoutMs", min: 500, max: 60_000, default: 10_000)
        v.validate!
        blocked = BLOCKED_AT.find { |re, _| re.match?(command) }
        raise AppError.bad_request("\"#{command}\" is not allowed here: #{blocked[1]}") if blocked

        render json: Gateway.request("modem.at", { command: command, timeout_ms: timeout_ms, user: principal.name })
      end

      def traffic
        require_scope!("admin")
        render json: { data: offline_fallback([]) { Gateway.request("modem.traffic") } }
      end

      def ports
        require_scope!("admin")
        result = offline_fallback({ "data" => [], "current" => Sim800c.config.modem.port_label }) do
          Gateway.request("modem.ports")
        end
        data = result["data"].map do |p|
          { path: p["path"], manufacturer: nil, vendorId: nil, productId: nil, target: p["target"] }
        end
        render json: { data: data, current: result["current"] }
      end

      private

      # Read-only views show nothing rather than an error while the runtime is down.
      def offline_fallback(value)
        yield
      rescue AppError => e
        raise unless e.status == 503

        value
      end
    end
  end
end
