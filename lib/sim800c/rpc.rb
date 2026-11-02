# frozen_string_literal: true

module Sim800c
  # Newline-delimited JSON over a Unix or TCP socket, between web processes and the runtime.
  #
  #   request:  {"v":1,"token":"…","op":"calls.dial","args":{…}}
  #   response: {"ok":true,"result":…} or {"ok":false,"error":{"status","code","message","details"}}
  #   "subscribe" answers {"ok":true}, then streams {"event":"…","data":…} lines and {"ping":true}.
  #
  # One request per connection. The token is derived from the app's secret_key_base, so every process
  # of the same app agrees on it without configuration.
  module RPC
    PROTOCOL_VERSION = 1
    MAX_LINE = 4 * 1024 * 1024
    DEFAULT_TIMEOUT = 15

    # The runtime cannot be reached (not running, wrong socket, refused).
    class Unavailable < Sim800c::Error; end

    # The runtime accepted the request but did not answer in time.
    class Timeout < Sim800c::Error; end

    module_function

    # "unix:///abs/path.sock", a bare path, or "tcp://host:port". Defaults to tmp/sockets/sim800c.sock.
    def url(config = Sim800c.config)
      return config.rpc.url.to_s if config.rpc.url.to_s != ""
      unless defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        raise ConfigError, "config.rpc.url is required outside a Rails app"
      end

      "unix://#{::Rails.root.join('tmp/sockets/sim800c.sock')}"
    end

    def token(config = Sim800c.config)
      return config.rpc.token.to_s if config.rpc.token.to_s != ""
      unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
        raise ConfigError, "config.rpc.token is required outside a Rails app"
      end

      ::Rails.application.key_generator.generate_key("sim800c rpc token", 32).unpack1("H*")
    end

    # [:unix, path] or [:tcp, host, port]
    def parse_url(url)
      if (m = %r{\Atcp://(\[[^\]]+\]|[^:/]+):(\d+)/?\z}.match(url))
        return [:tcp, m[1].delete_prefix("[").delete_suffix("]"), m[2].to_i]
      end

      path = url.sub(%r{\Aunix://}, "")
      raise ConfigError, "Invalid config.rpc.url #{url.inspect} (expected unix:///path or tcp://host:port)" if path.empty?

      [:unix, path]
    end

    # Seconds the runtime may spend on an operation (the client waits a little longer).
    def timeout_for(op, args = {}, config = Sim800c.config)
      case op
      when "ussd.send", "ussd.reply" then config.calls.ussd_timeout + 30
      when "calls.dial" then 45
      when "calls.hangup", "calls.answer", "calls.reject", "calls.dtmf", "modem.restart" then 30
      when "modem.refresh" then 90
      when "modem.at" then (args["timeout_ms"] || args[:timeout_ms] || 10_000).to_f / 1000 + 5
      else DEFAULT_TIMEOUT
      end
    end
  end
end

require_relative "rpc/server"
require_relative "rpc/client"
