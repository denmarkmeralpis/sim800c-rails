# frozen_string_literal: true

module Sim800c
  # The web processes' view of the runtime: live operations over RPC, best-effort change
  # notifications, and an offline status when the runtime cannot be reached.
  module Gateway
    NOT_RUNNING = "Gateway runtime is not running (start it with `bin/rails sim800c:run` or the sim800c Puma plugin)"

    module_function

    def client(config = Sim800c.config)
      RPC::Client.new(url: RPC.url(config), token: RPC.token(config))
    end

    # Runs an operation in the runtime and returns its result. Raises AppError (503 when the runtime
    # is down or does not answer).
    def request(op, args = {}, timeout: nil)
      client.request(op, args, timeout: timeout || RPC.timeout_for(op, args))
    rescue RPC::Unavailable => e
      Sim800c.logger.debug("[sim800c] RPC #{op} failed: #{e.message}")
      raise AppError.modem_unavailable(NOT_RUNNING)
    rescue RPC::Timeout
      raise AppError.modem_unavailable("Gateway runtime did not answer in time")
    end

    # Tells the runtime about changes made here so it broadcasts them (and wakes the SMS worker).
    # Never raises: if the runtime is down there is nobody to tell, and it re-reads the queue on start.
    #   sms_updated: ids, sms_status: ids, sms_deleted: ids, call_deleted: ids, log: ids, kick: true
    def notify(**changes)
      changes = changes.reject { |_k, v| v.nil? || v == false || (v.respond_to?(:empty?) && v.empty?) }
      return if changes.empty?

      client.request("notify", changes, timeout: 2)
      nil
    rescue StandardError => e
      Sim800c.logger.debug("[sim800c] notify skipped: #{e.message}")
      nil
    end

    # {modem, canOperate, reason, call, simulator}; an offline status when the runtime is down.
    def snapshot
      request("status")
    rescue AppError => e
      raise unless e.status == 503

      offline_snapshot(e.message)
    end

    def offline_snapshot(reason)
      { "modem" => offline_status(reason), "canOperate" => false, "reason" => reason, "call" => nil,
        "simulator" => Sim800c.config.modem.driver == :mock }
    end

    def offline_status(reason)
      config = Sim800c.config.modem
      ModemManager.camelize(
        connection: "disconnected", driver: config.driver.to_s, port: config.port_label, connected_at: nil,
        last_error: reason, reconnect_attempts: 0, next_reconnect_at: nil, device: nil,
        sim: { state: "unknown", detail: "Modem not connected", iccid: nil, imsi: nil },
        network: { registration: "unknown", registered: false, operator: nil },
        signal: Modem.signal_from(99, 99), power: { voltage: nil, percent: nil }, storage: { used: nil, total: nil },
        updated_at: Sim800c.iso(Sim800c.now)
      )
    end
  end
end
