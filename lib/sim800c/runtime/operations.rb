# frozen_string_literal: true

module Sim800c
  class Runtime
    # The RPC operations the runtime accepts (an allow-list). Each runs in a reactor task and
    # returns API-shaped data; errors come back as {status, code, message, details}.
    class Operations
      OPS = {
        "health" => :health,
        "status" => :status,
        "modem.signal" => :modem_signal,
        "modem.refresh" => :modem_refresh,
        "modem.reconnect" => :modem_reconnect,
        "modem.restart" => :modem_restart,
        "modem.at" => :modem_at,
        "modem.traffic" => :modem_traffic,
        "modem.ports" => :modem_ports,
        "calls.active" => :calls_active,
        "calls.dial" => :calls_dial,
        "calls.hangup" => :calls_hangup,
        "calls.answer" => :calls_answer,
        "calls.reject" => :calls_reject,
        "calls.dtmf" => :calls_dtmf,
        "ussd.send" => :ussd_send,
        "ussd.reply" => :ussd_reply,
        "ussd.cancel" => :ussd_cancel,
        "notify" => :notify,
        "simulator.snapshot" => :simulator_snapshot,
        "simulator.incoming_sms" => :simulator_incoming_sms,
        "simulator.incoming_call" => :simulator_incoming_call,
        "simulator.remote_hangup" => :simulator_remote_hangup,
        "simulator.signal" => :simulator_signal,
        "simulator.network" => :simulator_network,
        "simulator.sim" => :simulator_sim,
        "simulator.unplug" => :simulator_unplug,
        "simulator.freeze" => :simulator_freeze,
        "simulator.reboot" => :simulator_reboot
      }.freeze

      def initialize(runtime)
        @runtime = runtime
      end

      # Runs an operation; returns the RPC response payload.
      def dispatch(op, args)
        method = OPS[op]
        return error(AppError.bad_request("Unknown RPC operation #{op.inspect}")) unless method

        result = @runtime.call(timeout: RPC.timeout_for(op, args, @runtime.config)) { send(method, args) }
        { ok: true, result: result }
      rescue StandardError => e
        error(e)
      end

      # Registers a listener for every bus event; yields the current modem status first.
      # Returns a callable that removes the listeners.
      def subscribe(&block)
        bus = @runtime.bus
        # Registered on the reactor, where events are emitted, so nothing can arrive before the snapshot.
        listeners = @runtime.call(timeout: 5) do
          registered = Runtime::EventBus::NAMES.to_h { |name| [name, bus.on(name) { |data| block.call(name, data) }] }
          block.call("modem.status", @runtime.manager.status_json)
          registered
        end
        -> { listeners.each { |name, listener| bus.off(name, listener) } }
      end

      # The error envelope for an exception, as the HTTP API renders it.
      def self.error_for(error)
        case error
        when AppError then error
        when AT::CommandError
          status = %i[timeout disconnected].include?(error.kind) ? 503 : 502
          AppError.new(status, "modem_error", error.message)
        when Sim800c::TimeoutError
          AppError.new(503, "modem_unavailable", "The gateway runtime is busy; try again")
        else
          AppError.new(500, "internal_error", "Internal server error")
        end
      end

      private

      def error(exception)
        app_error = self.class.error_for(exception)
        if app_error.status >= 500 && !exception.is_a?(AppError) && !exception.is_a?(AT::CommandError)
          @runtime.logger.error("[sim800c] RPC operation failed: #{exception.class}: #{exception.message}\n" \
                                "#{exception.backtrace&.first(10)&.join("\n")}")
        end
        { ok: false, error: app_error.to_h }
      end

      def manager = @runtime.manager

      def actor(args)
        a = args["actor"] || {}
        { source: a["source"] || "api", user_id: a["user_id"], api_key_id: a["api_key_id"] }
      end

      def health(_args) = { modem: manager.status[:connection] }

      def status(_args) = @runtime.snapshot

      def modem_signal(_args) = manager.signal_history

      def modem_refresh(_args)
        manager.poll
        manager.status_json
      end

      def modem_reconnect(args)
        manager.force_reconnect(args["reason"] || "Manual reconnect")
        manager.status_json
      end

      def modem_restart(_args)
        manager.restart
        manager.status_json
      end

      def modem_at(args)
        command = args["command"].to_s
        raise AppError.bad_request("Modem is not connected") unless manager.connected?

        @runtime.events.info("modem", "AT console: #{command}", { user: args["user"] })
        begin
          response = manager.modem.raw(command, args.fetch("timeout_ms", 10_000).to_f / 1000)
          { ok: true, lines: response.lines, final: response.final, durationMs: response.duration_ms }
        rescue AT::CommandError => e
          { ok: false, error: e.message }
        end
      end

      def modem_traffic(_args) = manager.at.traffic.last(200)

      def modem_ports(_args)
        ports = @runtime.config.modem.driver == :serial ? Transport::Serial.list : []
        { data: ports, current: @runtime.config.modem.port_label }
      end

      def calls_active(_args) = @runtime.calls.active
      def calls_dial(args) = @runtime.calls.dial(args["number"].to_s, actor(args))
      def calls_hangup(_args) = @runtime.calls.hangup
      def calls_answer(_args) = @runtime.calls.answer
      def calls_reject(_args) = @runtime.calls.reject
      def calls_dtmf(args) = @runtime.calls.send_dtmf(args["digits"].to_s)

      def ussd_send(args) = @runtime.ussd.send_code(args["code"].to_s, actor(args))
      def ussd_reply(args) = @runtime.ussd.reply(args["text"].to_s)
      def ussd_cancel(_args) = @runtime.ussd.cancel

      # Changes made by a web process: re-broadcast them and wake the SMS worker.
      def notify(args)
        bus = @runtime.bus
        ids = ->(key) { Array(args[key]).grep(Integer) }
        status_ids = ids.call("sms_status")
        sms_ids = (ids.call("sms_updated") | status_ids).sort
        if sms_ids.any?
          SmsMessage.where(id: sms_ids).order(:id).each do |record|
            data = record.as_api
            bus.emit("sms.updated", data)
            bus.emit("sms.status", data) if status_ids.include?(record.id)
          end
        end
        bus.emit("sms.deleted", { ids: ids.call("sms_deleted") }) if ids.call("sms_deleted").any?
        bus.emit("call.deleted", { ids: ids.call("call_deleted") }) if ids.call("call_deleted").any?
        if ids.call("log").any?
          EventLogEntry.where(id: ids.call("log")).order(:id).each { |entry| bus.emit("log.entry", entry.as_api) }
        end
        @runtime.sms.kick if args["kick"]
        nil
      end

      def simulator
        @runtime.simulator || raise(AppError.not_found("Simulator (config.modem.driver is not :mock)"))
      end

      def simulate
        yield
      rescue Sim800c::Error => e
        raise AppError.bad_request(e.message)
      end

      def simulator_snapshot(_args) = simulator.snapshot

      def simulator_incoming_sms(args)
        simulate { simulator.inject_sms(args["from"].to_s, args["message"].to_s) }
        simulator.snapshot
      end

      def simulator_incoming_call(args)
        simulate { simulator.inject_call(args["from"].to_s) }
        simulator.snapshot
      end

      def simulator_remote_hangup(_args)
        simulator.remote_hangup
        simulator.snapshot
      end

      def simulator_signal(args)
        simulator.signal = args["rssi"].to_i
        @runtime.reactor.go { manager.poll }
        simulator.snapshot
      end

      def simulator_network(args)
        simulator.registration = args["registration"].to_i
        @runtime.reactor.go { manager.poll }
        simulator.snapshot
      end

      def simulator_sim(args)
        simulator.sim_inserted = args["inserted"] ? true : false
        simulator.snapshot
      end

      def simulator_unplug(args)
        simulator.unplug(args.fetch("seconds", 10).to_f)
        simulator.snapshot
      end

      def simulator_freeze(args)
        simulator.freeze(args.fetch("seconds", 30).to_f)
        simulator.snapshot
      end

      def simulator_reboot(_args)
        simulator.reboot
        simulator.snapshot
      end
    end
  end
end
