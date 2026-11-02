# frozen_string_literal: true

# The modem stack without Rails: reactor, transports, AT client, PDU codec, SIM800C driver,
# connection manager and serial bridge. `require "sim800c"` loads this plus the Rails engine.

require "logger"
require "json"
require "securerandom"
require "openssl"

require_relative "version"
require_relative "errors"

module Sim800c
  class << self
    attr_writer :logger

    # Defaults to Rails.logger when Rails is loaded, else STDOUT.
    def logger
      @logger || (defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger) ||
        (@default_logger ||= ::Logger.new($stdout, progname: "sim800c"))
    end

    # ISO-8601 with milliseconds in UTC, like JavaScript's Date#toISOString.
    def iso(time)
      time&.utc&.iso8601(3)
    end

    # Current time truncated to milliseconds, so in-memory values equal what the database returns.
    def now
      Time.now.utc.floor(3)
    end
  end
end

require_relative "configuration"
require_relative "emitter"
require_relative "promise"
require_relative "reactor"
require_relative "phone"
require_relative "pdu"
require_relative "at/errors"
require_relative "at/client"
require_relative "transport/base"
require_relative "transport/simulator"
require_relative "transport/tcp"
require_relative "transport/serial"
require_relative "modem"
require_relative "modem_manager"
require_relative "bridge"
