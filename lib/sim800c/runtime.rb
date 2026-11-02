# frozen_string_literal: true

require "fileutils"

module Sim800c
  # The gateway runtime: the one process that owns the modem. Composition root (like sms-gateway's
  # context.ts): builds the reactor, transport, connection manager and services, starts them in
  # order, serves RPC to the web processes, and stops everything gracefully.
  #
  #   bin/rails sim800c:run          # foreground, stops on INT / TERM
  #   Sim800c::Runtime.new.start     # embedded (tests)
  class Runtime
    TABLES = %w[sim800c_users sim800c_sessions sim800c_api_keys sim800c_sms_messages sim800c_sms_fragments
                sim800c_calls sim800c_ussd_sessions sim800c_event_log_entries sim800c_idempotency_keys].freeze

    attr_reader :config, :logger, :reactor, :bus, :events, :transport, :simulator, :manager, :sms, :calls, :ussd,
                :webhooks, :rpc_server

    # In a foreground process, also log to STDOUT when Rails logs only to a file.
    def self.log_to_stdout!
      return unless defined?(::Rails) && ::Rails.logger
      return if ActiveSupport::Logger.logger_outputs_to?(::Rails.logger, $stdout, $stderr)

      stdout = ActiveSupport::Logger.new($stdout)
      stdout.formatter = ::Logger::Formatter.new
      stdout.level = ::Rails.logger.level
      Sim800c.logger = ActiveSupport::BroadcastLogger.new(::Rails.logger, stdout)
    end

    # Runs in the foreground until INT or TERM, then stops gracefully (forced after `shutdown_timeout`).
    def self.run!(config: Sim800c.config, logger: Sim800c.logger, shutdown_timeout: 10)
      reader, writer = IO.pipe
      %w[INT TERM].each do |signal|
        Signal.trap(signal) do
          writer.write_nonblock(signal[0], exception: false)
        end
      end
      runtime = new(config: config, logger: logger).start
      logger.info("[sim800c] Runtime started (#{config.modem.driver} driver on #{config.modem.port_label}, " \
                  "RPC #{runtime.rpc_server&.description})")
      reader.wait_readable
      logger.info("[sim800c] Shutting down")
      Thread.new do
        sleep shutdown_timeout
        logger.error("[sim800c] Graceful shutdown timed out")
        exit!(1)
      end
      runtime.stop(timeout: shutdown_timeout)
      logger.info("[sim800c] Stopped")
    end

    # transport: optional ->(reactor) { Transport } replacing the configured one (tests).
    # rpc: false skips the RPC server.
    def initialize(config: Sim800c.config, logger: Sim800c.logger, transport: nil, rpc: true)
      @config = config
      @logger = logger
      @transport_factory = transport
      @rpc_enabled = rpc
      @started = false
    end

    def started? = @started

    def start
      raise Error, "runtime already started" if @started

      config.validate!
      ensure_schema!
      acquire_lock
      begin
        @reactor = Reactor.new(logger: logger)
        install_database_hooks
        @reactor.start
        @reactor.call(timeout: 30) do
          build
          start_services
        end
        if @rpc_enabled
          @rpc_server = RPC::Server.new(url: RPC.url(config), token: RPC.token(config), handler: Operations.new(self),
                                        logger: logger).start
        end
      rescue StandardError
        @reactor&.stop
        release_lock
        raise
      end
      @started = true
      self
    end

    # Stops the RPC server, the services and the modem link, in that order.
    def stop(timeout: 10)
      return unless @started

      @started = false
      @rpc_server&.stop
      begin
        @reactor.call(timeout: timeout) do
          @pruner&.cancel
          @calls.stop
          @ussd.stop
          @manager.stop
          @sms.stop
        end
      rescue StandardError => e
        logger.error("[sim800c] Error during shutdown: #{e.class}: #{e.message}")
      end
      @webhooks&.stop
      @reactor.stop
      release_lock
      nil
    end

    # Runs the block on the reactor (in a task) and returns its result.
    def call(timeout: 30, &block)
      raise Error, "runtime is not running" unless @reactor&.running?

      @reactor.call(timeout: timeout, &block)
    end

    # What GET /status and the event stream's hello need from the runtime.
    def snapshot
      {
        modem: @manager.status_json,
        canOperate: @manager.can_operate?,
        reason: @manager.unavailable_reason,
        call: @calls.active,
        simulator: !@simulator.nil?
      }
    end

    private

    def ensure_schema!
      missing = TABLES.reject { |table| ApplicationRecord.connection_pool.with_connection { |c| c.table_exists?(table) } }
      return if missing.empty?

      raise Error, "The sim800c database tables are missing (#{missing.join(', ')}). Run " \
                   "`bin/rails sim800c:install:migrations db:migrate`."
    end

    def build
      @bus = EventBus.new
      @events = EventLog.new(bus: @bus, logger: logger)
      modem = config.modem
      if modem.driver == :mock
        @simulator = Transport::Simulator.new(@reactor, time_scale: config.mock.time_scale,
                                                        sms_failure_rate: config.mock.sms_failure_rate)
      end
      @transport = @transport_factory&.call(@reactor) || @simulator ||
                   if modem.driver == :tcp
                     Transport::Tcp.new(@reactor, modem.tcp_host, modem.tcp_port)
                   else
                     Transport::Serial.new(@reactor, modem.serial_port, modem.baud_rate)
                   end

      @manager = ModemManager.new(@transport, reactor: @reactor, config: modem, sms_config: config.sms,
                                              events: @events, logger: logger)
      @sms = SmsService.new(reactor: @reactor, bus: @bus, manager: @manager, config: config.sms, events: @events,
                            logger: logger)
      @calls = CallService.new(reactor: @reactor, bus: @bus, manager: @manager, config: config.calls, events: @events,
                               logger: logger)
      @ussd = UssdService.new(reactor: @reactor, bus: @bus, manager: @manager, timeout: config.calls.ussd_timeout,
                              events: @events, logger: logger)
      @webhooks = Webhooks.new(config: config.webhook, bus: @bus, reactor: @reactor, logger: logger)
      @manager.on(:status) { @bus.emit("modem.status", @manager.status_json) }
    end

    def start_services
      auth = config.auth
      if User.ensure_admin!(auth.admin_username, auth.admin_password)
        logger.info("[sim800c] Created admin account \"#{auth.admin_username}\" from config.auth.admin_password")
      elsif User.needs_setup?
        logger.warn("[sim800c] No accounts yet: open the dashboard to create the admin account (first-time setup)")
      end
      @sms.start
      @calls.start
      @ussd.start
      @webhooks.start
      @manager.start
      @pruner = @reactor.every(3600) do
        Session.prune!
        IdempotencyKey.prune!
      end
    end

    # Fibers share the reactor thread's database lease: never hold one across jobs, and never let a
    # task suspend while a transaction is open (another task could run SQL inside it).
    def install_database_hooks
      @reactor.after_job = lambda do
        ActiveRecord::Base.connection_handler.connection_pool_list(:all).each do |pool|
          connection = pool.active_connection?
          pool.release_connection if connection && !connection.transaction_open?
        end
      end
      @reactor.await_guard = lambda do
        open = ActiveRecord::Base.connection_handler.connection_pool_list(:all).any? do |pool|
          pool.active_connection?&.transaction_open?
        end
        raise Error, "a reactor task cannot wait while a database transaction is open" if open
      end
    end

    def lock_path
      return config.lock_file.to_s if config.lock_file
      return nil unless defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root

      ::Rails.root.join("tmp/pids/sim800c.lock").to_s
    end

    def acquire_lock
      path = lock_path or return
      FileUtils.mkdir_p(File.dirname(path))
      lock = File.open(path, File::RDWR | File::CREAT, 0o644)
      unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        lock.close
        raise Error, "Another sim800c runtime is already running (lock file #{path})"
      end
      lock.truncate(0)
      lock.write("#{Process.pid}\n")
      lock.flush
      @lock = lock
    end

    def release_lock
      @lock&.flock(File::LOCK_UN)
      @lock&.close
      @lock = nil
    end
  end
end

require_relative "runtime/event_bus"
require_relative "runtime/event_log"
require_relative "runtime/serial_queue"
require_relative "runtime/sms_service"
require_relative "runtime/call_service"
require_relative "runtime/ussd_service"
require_relative "runtime/webhooks"
require_relative "runtime/operations"
