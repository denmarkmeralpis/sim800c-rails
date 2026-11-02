# frozen_string_literal: true

require "unit_helper"
require "support/recording_events"

# The connection manager, driver, AT client and codec against the simulator at 20x speed.
class ModemManagerTest < Minitest::Test
  include ModemStackHelpers

  def start(**overrides)
    @config = modem_config(**overrides)
    @reactor = Sim800c::Reactor.new.start
    @events = RecordingEvents.new
    @sim, @manager = @reactor.call(timeout: 2) do
      sim = Sim800c::Transport::Simulator.new(@reactor, time_scale: @config.mock.time_scale)
      manager = Sim800c::ModemManager.new(sim, reactor: @reactor, config: @config.modem, sms_config: @config.sms,
                                               events: @events)
      manager.start
      [sim, manager]
    end
    wait_for(5, "modem ready") { on_reactor { @manager.can_operate? } }
  end

  def teardown
    on_reactor { @manager.stop } if @manager
    @reactor&.stop
  end

  def on_reactor(&block) = @reactor.call(timeout: 30, &block)

  def test_initialises_the_modem_and_reports_full_status
    start
    s = on_reactor { @manager.status }
    assert_equal "ready", s[:connection]
    assert_equal "SIMCOM_SIM800C", s[:device][:model]
    assert_equal "869170031234567", s[:device][:imei]
    assert_equal "ready", s[:sim][:state]
    assert_equal "8963012345678901234f", s[:sim][:iccid]
    assert s[:network][:registered]
    assert_equal "SIMULATED GSM", s[:network][:operator]
    assert_operator s[:signal][:dbm], :<, 0
    assert_equal 30, s[:storage][:total]
    assert_equal 4120, s[:power][:voltage]
    json = on_reactor { @manager.status_json }
    assert_equal "ready", json["sim"]["state"]
    assert json.key?("connectedAt")
    assert s.frozen? && s[:sim].frozen?
  end

  def test_reconnects_after_a_usb_unplug
    start
    on_reactor { @sim.unplug(0.6) }
    wait_for(2, "disconnect detected") { on_reactor { @manager.status[:connection] } != "ready" }
    assert_equal "unknown", on_reactor { @manager.status[:sim][:state] }
    wait_for(8, "reconnected") { on_reactor { @manager.can_operate? } }
    assert(@events.messages.any? { |m| m.start_with?("Modem disconnected") })
  end

  def test_reconnects_when_the_modem_stops_responding
    start(command_timeout: 0.5)
    on_reactor { @sim.freeze(600) }
    wait_for(8, "watchdog trip") { on_reactor { @manager.status[:connection] } != "ready" }
    on_reactor { @sim.freeze(0) } # modem comes back to life
    wait_for(15, "recovered") { on_reactor { @manager.can_operate? } }
    assert(@events.messages.any? { |m| m.match?(/stopped responding/) })
  end

  def test_re_initialises_after_a_spontaneous_modem_reboot
    start
    on_reactor { @sim.reboot }
    wait_for(6, "reinit") { @events.messages.any? { |m| m.match?(/Re-initialising/) } }
    wait_for(5, "ready again") { on_reactor { @manager.can_operate? } }
  end

  def test_reports_why_it_cannot_operate
    start
    on_reactor do
      @sim.registration = 0
      @manager.poll
    end
    refute on_reactor { @manager.can_operate? }
    assert_equal "Not registered on the network (not registered)", on_reactor { @manager.unavailable_reason }
    assert(@events.messages.any? { |m| m.start_with?("Lost network registration") })
    on_reactor do
      @sim.registration = 1
      @manager.poll
    end
    assert on_reactor { @manager.can_operate? }
  end

  def test_force_reconnect_and_restart
    start
    on_reactor { @manager.force_reconnect("Manual reconnect by test") }
    assert_equal "disconnected", on_reactor { @manager.status[:connection] }
    wait_for(5, "reconnected") { on_reactor { @manager.can_operate? } }
    on_reactor { @manager.restart }
    wait_for(6, "reinit after restart") { @events.messages.count { |m| m.match?(/Re-initialising/) } >= 1 }
    wait_for(5, "ready again") { on_reactor { @manager.can_operate? } }
  end

  def test_keeps_signal_history
    start
    wait_for(3, "two samples") { on_reactor { @manager.signal_history.size } >= 2 }
    sample = on_reactor { @manager.signal_history.last }
    assert_match(/\A\d{4}-\d\d-\d\dT.*Z\z/, sample[:t])
    assert_kind_of Integer, sample[:rssi]
  end

  def test_backs_off_when_the_modem_cannot_be_opened
    start
    on_reactor { @sim.unplug(30) }
    wait_for(5, "two failed attempts") { on_reactor { @manager.status[:reconnect_attempts] } >= 2 }
    s = on_reactor { @manager.status }
    assert_equal "disconnected", s[:connection]
    assert_match(/unplugged/, s[:last_error])
    refute_nil s[:next_reconnect_at]
  end
end
