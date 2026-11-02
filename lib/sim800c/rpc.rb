# frozen_string_literal: true

require "tmpdir"

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
    # Unix socket paths are limited to 104 bytes on macOS and 108 on Linux (including a NUL).
    MAX_SOCKET_PATH = 100

    # The runtime cannot be reached (not running, wrong socket, refused).
    class Unavailable < Sim800c::Error; end

    # The runtime accepted the request but did not answer in time.
    class Timeout < Sim800c::Error; end

    module_function

    # "unix:///abs/path.sock", a bare path, or "tcp://host:port". Defaults to tmp/sockets/sim800c.sock
    # in the app, or to a short per-app path in the system temp directory when that one is too long.
    def url(config = Sim800c.config)
      return config.rpc.url.to_s if config.rpc.url.to_s != ""
      unless defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        raise ConfigError, "config.rpc.url is required outside a Rails app"
      end

      "unix://#{default_socket_path(::Rails.root)}"
    end

    # tmp/sockets/sim800c.sock in the app, or a short path unique to the app in a private directory
    # of this user under the system temp directory when that one is too long. The same in every
    # process of the app.
    def default_socket_path(root)
      path = File.join(root.to_s, "tmp/sockets/sim800c.sock")
      return path if path.bytesize <= MAX_SOCKET_PATH

      File.join(private_dir, "#{OpenSSL::Digest::SHA256.hexdigest(root.to_s)[0, 16]}.sock")
    end

    def private_dir = File.join(Dir.tmpdir, "sim800c-#{Process.euid}")

    # For a socket in the private temp directory: creates the directory (0700) and makes sure nobody
    # else owns or can write to it, so another local user cannot squat on the path and collect tokens.
    def secure_socket_dir!(path)
      dir = File.dirname(path)
      return unless dir == private_dir

      begin
        Dir.mkdir(dir, 0o700)
      rescue Errno::EEXIST
        nil
      end
      stat = File.lstat(dir)
      return if stat.directory? && stat.uid == Process.euid && (stat.mode & 0o077).zero?

      raise ConfigError, "Refusing to use #{dir} for the RPC socket: it must be a directory owned by this user " \
                         "with mode 0700. Set config.rpc.url (SIM800C_RPC_URL) to another path."
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

    # Seconds the runtime may spend on an operation. Modem commands run one at a time, so besides
    # its own timeout an operation may wait for the command in progress (up to an SMS submission's
    # send timeout); call control and USSD jump the rest of the queue.
    def timeout_for(op, args = {}, config = Sim800c.config)
      in_flight = config.sms.send_timeout + config.modem.command_timeout
      case op
      when "ussd.send", "ussd.reply" then config.calls.ussd_timeout + 20 + in_flight
      when "calls.dial" then 30 + in_flight
      when "calls.hangup", "calls.answer", "calls.reject", "ussd.cancel", "modem.restart" then 20 + in_flight
      when "calls.dtmf" then 25 + in_flight
      when "modem.refresh" then 90 + in_flight
      # The console's commands queue behind everything else.
      when "modem.at" then ((args["timeout_ms"] || args[:timeout_ms] || 10_000).to_f / 1000) + 120 + in_flight
      else DEFAULT_TIMEOUT
      end
    end
  end
end

require_relative "rpc/server"
require_relative "rpc/client"
