# frozen_string_literal: true

# Stands in for the runtime's event log in tests of the modem stack alone.
class RecordingEvents
  attr_reader :entries

  def initialize
    @entries = []
    @lock = Mutex.new
  end

  %i[info warn error].each do |level|
    define_method(level) do |category, message, data = nil|
      @lock.synchronize { @entries << { level: level, category: category, message: message, data: data } }
    end
  end

  def messages
    @lock.synchronize { @entries.map { |e| e[:message] } }
  end
end

module ModemStackHelpers
  def modem_config(**overrides)
    Sim800c::Configuration.new.tap do |c|
      c.modem.driver = :mock
      c.modem.poll_interval = 1
      c.modem.command_timeout = 2
      c.modem.reconnect_min = 0.2
      c.modem.reconnect_max = 1
      c.mock.time_scale = 0.05
      overrides.each { |k, v| c.modem.public_send("#{k}=", v) }
    end
  end
end
