# frozen_string_literal: true

module Sim800c
  # Owns the modem connection: opens the transport, initialises the SIM800C, polls status,
  # detects disconnects / unresponsiveness / reboots, and reconnects with exponential backoff.
  #
  # Reactor-thread only. Emits :status (frozen status Hash), :event (modem event Hash) and
  # :services_ready (SIM ready and SMS / call reporting configured; after every (re)connect).
  #
  # `events` receives user-visible log entries: #info / #warn / #error(category, message, data = nil).
  class ModemManager
    include Emitter

    SIGNAL_HISTORY = 240
    REINIT_DEBOUNCE = 3

    attr_reader :at, :modem, :transport

    def self.camelize(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_s.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }, camelize(v)] }
      when Array then value.map { |v| camelize(v) }
      else value
      end
    end

    def self.deep_freeze(value)
      case value
      when Hash then value.each_value { |v| deep_freeze(v) }
      when Array then value.each { |v| deep_freeze(v) }
      end
      value.freeze
    end

    def initialize(transport, reactor:, config:, sms_config:, events:, logger: Sim800c.logger)
      @transport = transport
      @reactor = reactor
      @config = config
      @events = events
      @logger = logger
      @state = self.class.deep_freeze(initial_status)
      @stopped = true
      @connecting = false
      @services_configured = false
      # Set when the configured PIN is rejected; never retried, since 3 wrong PINs lock the SIM.
      @pin_rejected = false
      @polling = false
      @consecutive_timeouts = 0
      @reconnect_timer = nil
      @poll_timer = nil
      @reinit_timer = nil
      @signal_history = []

      @at = AT::Client.new(transport, reactor: reactor, logger: logger, default_timeout: config.command_timeout,
                                      log_traffic: config.log_traffic)
      @modem = Modem.new(@at, storage: sms_config.storage, delivery_reports: sms_config.delivery_reports, logger: logger)

      @modem.on(:event) { |e| on_modem_event(e) }
      transport.on(:close) { |error| on_transport_close(error) }
      transport.on(:error) { |error| @logger.warn("[sim800c] Transport error: #{error.message}") }
      @at.on(:success) { @consecutive_timeouts = 0 }
      @at.on(:timeout) do |command|
        @consecutive_timeouts += 1
        @logger.warn("[sim800c] AT command timed out: #{command} (#{@consecutive_timeouts} consecutive)")
        if @consecutive_timeouts >= @config.max_consecutive_timeouts && @state[:connection] == "ready"
          count = @consecutive_timeouts
          @reactor.go { force_reconnect("Modem stopped responding (#{count} consecutive timeouts)") }
        end
      end
    end

    # The current status (frozen, snake_case keys).
    def status = @state

    # The status as the API returns it (camelCase keys).
    def status_json = self.class.camelize(@state)

    # Recent signal samples: [{ t: ISO time, rssi:, dbm: }]
    def signal_history = @signal_history.dup

    def connected? = @state[:connection] == "ready"

    # Why the modem cannot currently place calls / send SMS, or nil when it can.
    def unavailable_reason
      s = @state
      return "Modem is #{s[:connection]}#{": #{s[:last_error]}" if s[:last_error]}" if s[:connection] != "ready"
      return "SIM not ready: #{s[:sim][:detail] || s[:sim][:state]}" if s[:sim][:state] != "ready"
      return "Not registered on the network (#{s[:network][:registration].sub('_', ' ')})" unless s[:network][:registered]
      return "Modem is still initialising" unless @services_configured

      nil
    end

    def can_operate? = unavailable_reason.nil?

    def start
      return unless @stopped

      @stopped = false
      @reactor.go("modem connect") { connect }
    end

    # Call inside a reactor task.
    def stop
      @stopped = true
      @reconnect_timer&.cancel
      @reinit_timer&.cancel
      stop_polling
      @at.fail_all("Application shutting down")
      close_transport
    end

    # Drops the connection and reconnects promptly (manual action or watchdog). Call inside a task.
    def force_reconnect(reason)
      return if @stopped

      @events.warn("modem", "Reconnecting: #{reason}")
      stop_polling
      @at.fail_all(reason)
      @consecutive_timeouts = 0
      @services_configured = false
      update(connection: "disconnected", last_error: reason, reconnect_attempts: 0, **offline_status)
      close_transport
      @reconnect_timer&.cancel
      @reconnect_timer = nil
      schedule_reconnect
    end

    # Reboots the modem (AT+CFUN=1,1); re-initialisation happens when it announces itself.
    def restart
      @events.warn("modem", "Restarting modem (AT+CFUN=1,1)")
      @services_configured = false
      @modem.restart
      schedule_reinit
    end

    # Refreshes SIM, network, signal, power and storage status. Call inside a task.
    def poll
      return if @polling || @state[:connection] != "ready"

      @polling = true
      begin
        refresh_sim
        signal = @modem.signal
        registration = @modem.registration
        registered = %w[home roaming].include?(registration)
        operator = if registered
                     begin
                       @modem.operator
                     rescue StandardError
                       @state[:network][:operator]
                     end
                   end
        power = begin
          @modem.battery
        rescue StandardError
          @state[:power]
        end
        storage = if @services_configured
                    begin
                      @modem.storage
                    rescue StandardError
                      @state[:storage]
                    end
                  else
                    @state[:storage]
                  end

        if registered != @state[:network][:registered]
          if registered
            @events.info("network", "Registered on #{operator || 'network'} (#{registration})")
          else
            @events.warn("network", "Lost network registration (#{registration.sub('_', ' ')})")
          end
        end
        used = storage[:used]
        total = storage[:total]
        if used.is_a?(Numeric) && total.is_a?(Numeric) && total.positive? && used >= total
          @events.warn("sms", "SIM message storage is full (#{used}/#{total})")
        end

        @signal_history << { t: Sim800c.iso(Sim800c.now), rssi: signal[:rssi], dbm: signal[:dbm] }.freeze
        @signal_history.shift if @signal_history.size > SIGNAL_HISTORY
        update(signal: signal, network: { registration: registration, registered: registered, operator: operator },
               power: power, storage: storage)
      rescue StandardError => e
        @logger.debug("[sim800c] Status poll failed: #{e.message}")
      ensure
        @polling = false
      end
    end

    private

    def initial_status
      {
        connection: "disconnected",
        driver: @config.driver.to_s,
        port: @config.port_label,
        connected_at: nil,
        last_error: nil,
        reconnect_attempts: 0,
        next_reconnect_at: nil,
        device: nil,
        sim: { state: "unknown", detail: nil, iccid: nil, imsi: nil },
        network: { registration: "unknown", registered: false, operator: nil },
        signal: Modem.signal_from(99, 99),
        power: { voltage: nil, percent: nil },
        storage: { used: nil, total: nil },
        updated_at: nil
      }
    end

    def connect
      return if @stopped || @connecting

      @connecting = true
      @reconnect_timer&.cancel
      @reconnect_timer = nil
      update(connection: "connecting", next_reconnect_at: nil)
      begin
        @reactor.await(@transport.open) unless @transport.open?
        update(connection: "initializing")
        initialize_modem
        update(connection: "ready", connected_at: Sim800c.iso(Sim800c.now), last_error: nil, reconnect_attempts: 0)
        device = @state[:device]
        @events.info("modem", "Connected to #{device&.dig(:model) || 'modem'} on #{@transport.description}", device)
        poll
        start_polling
      rescue StandardError => e
        message = e.message
        @events.error("modem", "Connection failed: #{message}")
        update(connection: "disconnected", last_error: message, **offline_status)
        @at.fail_all(message)
        close_transport
        schedule_reconnect
      ensure
        @connecting = false
      end
    end

    def initialize_modem
      @services_configured = false
      @modem.sync
      @modem.setup
      update(device: @modem.device_info)
    end

    def close_transport
      @reactor.await(@transport.close)
    rescue StandardError
      nil
    end

    def schedule_reconnect
      return if @stopped || @reconnect_timer

      attempt = @state[:reconnect_attempts] + 1
      base = [@config.reconnect_max, @config.reconnect_min * (2**[attempt - 1, 30].min)].min
      delay = base * (0.8 + (rand * 0.4))
      update(reconnect_attempts: attempt, next_reconnect_at: Sim800c.iso(Sim800c.now + delay))
      @logger.info("[sim800c] Scheduling modem reconnect (attempt #{attempt}, in #{delay.round(1)}s)")
      @reconnect_timer = @reactor.after(delay) do
        @reconnect_timer = nil
        connect
      end
    end

    def on_transport_close(error)
      was_connected = @state[:connection] != "disconnected"
      stop_polling
      @services_configured = false
      @at.fail_all(error ? "Modem disconnected: #{error.message}" : "Modem port closed")
      return if @stopped
      return unless was_connected && !@connecting

      reason = error ? "Modem disconnected: #{error.message}" : "Modem port closed unexpectedly"
      @events.error("modem", reason)
      update(connection: "disconnected", last_error: reason, **offline_status)
      schedule_reconnect
    end

    # Live readings are unknown while the modem is unreachable; identity fields are kept.
    def offline_status
      {
        sim: @state[:sim].merge(state: "unknown", detail: "Modem not connected"),
        network: { registration: "unknown", registered: false, operator: nil },
        signal: Modem.signal_from(99, 99)
      }
    end

    def start_polling
      stop_polling
      @poll_timer = @reactor.every(@config.poll_interval) { poll }
    end

    def stop_polling
      @poll_timer&.cancel
      @poll_timer = nil
    end

    def refresh_sim
      sim = @modem.sim_state

      if sim[:state] == "pin_required" && @config.sim_pin && !@pin_rejected
        begin
          @modem.enter_pin(@config.sim_pin)
          @events.info("sim", "SIM PIN accepted")
          sim = @modem.sim_state
        rescue StandardError => e
          raise if e.is_a?(AT::CommandError) && %i[timeout disconnected].include?(e.kind)

          @pin_rejected = true
          @events.error("sim", "SIM PIN rejected (#{e.message}). Not retrying to avoid locking the SIM — fix " \
                               "config.modem.sim_pin and restart.")
        end
      end

      if sim[:state] != @state[:sim][:state]
        level = sim[:state] == "ready" ? :info : :warn
        @events.public_send(level, "sim", "SIM status: #{sim[:detail]}")
      end

      identity = { iccid: @state[:sim][:iccid], imsi: @state[:sim][:imsi] }
      if sim[:state] == "ready"
        identity = @modem.sim_identity unless identity[:iccid]
        configure_services unless @services_configured
      else
        @services_configured = false
      end
      update(sim: { state: sim[:state], detail: sim[:detail], **identity })
    end

    def configure_services
      @modem.configure_services
      @services_configured = true
      @logger.info("[sim800c] SMS and call services configured")
      emit(:services_ready)
    rescue StandardError => e
      raise if e.is_a?(AT::CommandError) && %i[timeout disconnected].include?(e.kind)

      # Commonly "SIM busy" for a few seconds after boot; the next poll retries.
      @logger.warn("[sim800c] Service configuration failed, will retry: #{e.message}")
    end

    def on_modem_event(event)
      case event[:type]
      when :boot
        if @state[:connection] == "ready"
          @logger.info("[sim800c] Modem boot URC received: #{event[:line]}")
          schedule_reinit
        end
      when :sim
        if event[:state] != @state[:sim][:state]
          @services_configured = false if event[:state] != "ready"
          update(sim: @state[:sim].merge(state: event[:state], detail: event[:detail]))
          schedule_reinit if event[:state] == "ready"
        end
      when :power
        @events.public_send(event[:fatal] ? :error : :warn, "power", "Modem power warning: #{event[:line]}")
      when :other
        @logger.debug("[sim800c] Unhandled URC: #{event[:line]}")
      end
      emit(:event, event)
    end

    # The modem rebooted (or the SIM became ready): re-apply configuration once the URC burst settles.
    def schedule_reinit
      @reinit_timer&.cancel
      @reinit_timer = @reactor.after(REINIT_DEBOUNCE) do
        next if @stopped || @state[:connection] != "ready"

        begin
          @events.info("modem", "Re-initialising modem after reboot / SIM change")
          initialize_modem
          poll
        rescue StandardError => e
          force_reconnect("Re-initialisation failed: #{e.message}")
        end
      end
    end

    def update(patch)
      nxt = @state.merge(patch)
      return if nxt.except(:updated_at) == @state.except(:updated_at)

      @state = self.class.deep_freeze(nxt.merge(updated_at: Sim800c.iso(Sim800c.now)))
      emit(:status, @state)
    end
  end
end
