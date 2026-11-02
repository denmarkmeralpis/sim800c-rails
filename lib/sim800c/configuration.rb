# frozen_string_literal: true

require "uri"

module Sim800c
  # Settings for the gateway. Durations are in seconds.
  #
  #   Sim800c.configure do |config|
  #     config.modem.driver = :serial
  #     config.modem.serial_port = "/dev/ttyUSB0"
  #     config.webhook.url = "https://example.com/hooks/sms"
  #   end
  class Configuration
    DRIVERS = %i[serial tcp mock].freeze
    STORAGES = %w[SM ME MT].freeze

    # Modem link and connection management.
    class Modem
      # :serial (a SIM800C on this machine), :tcp (through the serial bridge) or :mock (simulator)
      attr_reader :driver
      attr_accessor :serial_port, :baud_rate, :tcp_host, :tcp_port, :sim_pin, :command_timeout, :poll_interval,
                    :reconnect_min, :reconnect_max, :max_consecutive_timeouts, :log_traffic

      def initialize
        @driver = :serial
        @serial_port = nil
        @baud_rate = 115_200
        @tcp_host = nil
        @tcp_port = 7070
        @sim_pin = nil
        @command_timeout = 10
        @poll_interval = 15
        @reconnect_min = 2
        @reconnect_max = 60
        @max_consecutive_timeouts = 3
        @log_traffic = false
      end

      def driver=(value)
        @driver = value.to_s.strip.downcase.to_sym
      end

      # The serial device, or a display label for the tcp / mock drivers.
      def port_label
        case driver
        when :mock then "simulator"
        when :tcp then "tcp://#{tcp_host}:#{tcp_port}"
        else serial_port.to_s
        end
      end
    end

    class Sms
      attr_accessor :storage, :delivery_reports, :max_attempts, :retry_base, :max_parts, :send_timeout,
                    :concat_timeout, :queue_poll_interval

      def initialize
        @storage = "SM"
        @delivery_reports = true
        @max_attempts = 3
        @retry_base = 15
        @max_parts = 6
        @send_timeout = 60
        @concat_timeout = 600
        # The runtime also checks the queue this often, for messages queued while it could not be woken.
        @queue_poll_interval = 5
      end
    end

    class Calls
      attr_accessor :ring_timeout, :poll_interval, :ussd_timeout

      def initialize
        @ring_timeout = 60
        @poll_interval = 2
        @ussd_timeout = 30
      end
    end

    class Auth
      # cookie_secure: nil sets Secure on the session cookie when the request is HTTPS.
      # rate_limit_store: an ActiveSupport::Cache::Store; nil uses Rails.cache, or a per-process
      # memory store when Rails.cache does not keep data (null store).
      attr_accessor :admin_username, :admin_password, :session_ttl, :cookie_secure, :api_rate_limit_per_min,
                    :login_rate_limit, :login_rate_period, :rate_limit_store

      def initialize
        @admin_username = "admin"
        @admin_password = nil
        @session_ttl = 24 * 3600
        @cookie_secure = nil
        @api_rate_limit_per_min = 120
        @login_rate_limit = 10
        @login_rate_period = 15 * 60
        @rate_limit_store = nil
      end
    end

    class Webhook
      # events: nil sends every webhook event; otherwise a list such as %w[sms.received sms.status]
      attr_accessor :url, :secret, :events, :timeout

      def initialize
        @url = nil
        @secret = nil
        @events = nil
        @timeout = 10
      end
    end

    class Mock
      attr_accessor :time_scale, :sms_failure_rate

      def initialize
        @time_scale = 1.0
        @sms_failure_rate = 0.0
      end
    end

    class Rpc
      # url: "unix:///path/to.sock", a bare socket path, or "tcp://host:port". nil uses
      # tmp/sockets/sim800c.sock in the Rails app. token: nil derives one from secret_key_base.
      attr_accessor :url, :token, :timeout

      def initialize
        @url = nil
        @token = nil
        @timeout = 30
      end
    end

    attr_reader :modem, :sms, :calls, :auth, :webhook, :mock, :rpc
    # lock_file: where the runtime takes its single-instance lock (nil: tmp/pids/sim800c.lock).
    attr_accessor :logger, :lock_file

    def initialize
      @modem = Modem.new
      @sms = Sms.new
      @calls = Calls.new
      @auth = Auth.new
      @webhook = Webhook.new
      @mock = Mock.new
      @rpc = Rpc.new
      @logger = nil
      @lock_file = nil
    end

    # Raises ConfigError listing every invalid setting.
    def validate!
      issues = []
      check = ->(ok, message) { issues << message unless ok }
      at_least = lambda do |name, value, min|
        check.call(value.is_a?(Numeric) && value >= min, "#{name} must be a number >= #{min} (got #{value.inspect})")
      end

      check.call(DRIVERS.include?(modem.driver), "modem.driver must be one of #{DRIVERS.join(', ')}")
      at_least.call("modem.baud_rate", modem.baud_rate, 1200)
      at_least.call("modem.tcp_port", modem.tcp_port, 1)
      at_least.call("modem.command_timeout", modem.command_timeout, 0.5)
      at_least.call("modem.poll_interval", modem.poll_interval, 1)
      at_least.call("modem.reconnect_min", modem.reconnect_min, 0.1)
      at_least.call("modem.reconnect_max", modem.reconnect_max, 1)
      at_least.call("modem.max_consecutive_timeouts", modem.max_consecutive_timeouts, 1)
      check.call(STORAGES.include?(sms.storage.to_s), "sms.storage must be one of #{STORAGES.join(', ')}")
      at_least.call("sms.max_attempts", sms.max_attempts, 1)
      at_least.call("sms.retry_base", sms.retry_base, 0.1)
      at_least.call("sms.max_parts", sms.max_parts, 1)
      check.call(sms.max_parts.is_a?(Numeric) && sms.max_parts <= 255, "sms.max_parts must be <= 255")
      at_least.call("sms.send_timeout", sms.send_timeout, 1)
      at_least.call("sms.concat_timeout", sms.concat_timeout, 1)
      at_least.call("sms.queue_poll_interval", sms.queue_poll_interval, 0.1)
      at_least.call("calls.ring_timeout", calls.ring_timeout, 5)
      at_least.call("calls.poll_interval", calls.poll_interval, 0.2)
      at_least.call("calls.ussd_timeout", calls.ussd_timeout, 1)
      check.call(auth.admin_username.to_s.match?(/\A[a-zA-Z0-9._-]{3,40}\z/),
                 "auth.admin_username must be 3-40 characters: letters, digits, dot, dash or underscore")
      at_least.call("auth.session_ttl", auth.session_ttl, 60)
      at_least.call("auth.api_rate_limit_per_min", auth.api_rate_limit_per_min, 1)
      at_least.call("auth.login_rate_limit", auth.login_rate_limit, 1)
      at_least.call("auth.login_rate_period", auth.login_rate_period, 1)
      at_least.call("webhook.timeout", webhook.timeout, 1)
      check.call(mock.time_scale.is_a?(Numeric) && mock.time_scale.positive?, "mock.time_scale must be > 0")
      check.call(mock.sms_failure_rate.is_a?(Numeric) && mock.sms_failure_rate.between?(0, 1),
                 "mock.sms_failure_rate must be between 0 and 1")
      if webhook.url.to_s != ""
        uri = begin
          URI.parse(webhook.url.to_s)
        rescue URI::InvalidURIError
          nil
        end
        check.call(uri.is_a?(URI::HTTP) && uri.host, "webhook.url must be an http(s) URL")
      end
      raise ConfigError, "Invalid configuration:\n  #{issues.join("\n  ")}" if issues.any?

      if modem.driver == :serial && modem.serial_port.to_s.strip.empty?
        raise ConfigError, "modem.serial_port is required when modem.driver is :serial (e.g. /dev/ttyUSB0 or " \
                           "/dev/cu.usbserial-110). Run `bin/rails sim800c:ports` to list ports, or set " \
                           "modem.driver to :mock to use the built-in simulator."
      end
      if modem.driver == :tcp && modem.tcp_host.to_s.strip.empty?
        raise ConfigError, "modem.tcp_host is required when modem.driver is :tcp (the machine running the serial bridge)."
      end
      raise ConfigError, "modem.reconnect_max must be >= modem.reconnect_min" if modem.reconnect_max < modem.reconnect_min

      self
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
      config
    end

    def reset_config!
      @config = Configuration.new
    end
  end
end
