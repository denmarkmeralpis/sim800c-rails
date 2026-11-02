# frozen_string_literal: true

require "unit_helper"
require "pty"
require "support/recording_events"

# The serial transport against a pseudo-terminal: stty configuration, locking, both directions.
class SerialTransportTest < Minitest::Test
  def setup
    @master, @slave = PTY.open
    @reactor = Sim800c::Reactor.new.start
    @transport = @reactor.call(timeout: 2) { Sim800c::Transport::Serial.new(@reactor, @slave.path, 115_200) }
    @received = Thread::Queue.new
    @closed = Thread::Queue.new
    @reactor.call(timeout: 2) do
      @transport.on(:data) { |chunk| @received << chunk }
      @transport.on(:close) { |error| @closed << (error || :clean) }
    end
  end

  def teardown
    @reactor.call(timeout: 2) { @reactor.await(@transport.close) } if @reactor.running?
    @reactor.stop
    @master.close unless @master.closed?
    @slave.close unless @slave.closed?
  end

  def open_transport = @reactor.call(timeout: 5) { @reactor.await(@transport.open) }

  def test_configures_the_line_and_moves_bytes_both_ways
    open_transport
    settings = IO.popen(["stty", "-a"], in: @slave, err: %i[child out], &:read)
    flags = settings.split(/[\s;]+/)
    %w[-echo -icanon -isig -opost cs8 -parenb -cstopb clocal cread -crtscts -ixon -ixoff].each do |flag|
      assert_includes flags, flag
    end
    assert_match(/speed 115200 baud/, settings)

    @reactor.call(timeout: 2) { @reactor.await(@transport.write("AT\r")) }
    assert_equal "AT\r", @master.readpartial(100)

    @master.write("\r\nOK\r\n")
    assert_equal "\r\nOK\r\n", @received.pop(timeout: 2)
    assert_equal "#{@slave.path} @ 115200 baud", @transport.description
  end

  def test_refuses_a_port_another_program_has_locked
    open_transport
    other = @reactor.call(timeout: 2) { Sim800c::Transport::Serial.new(@reactor, @slave.path, 115_200) }
    error = assert_raises(Sim800c::Error) { @reactor.call(timeout: 5) { @reactor.await(other.open) } }
    assert_match(/another program is using the serial port/, error.message)
  end

  def test_reports_a_missing_device_clearly
    missing = @reactor.call(timeout: 2) { Sim800c::Transport::Serial.new(@reactor, "/dev/does-not-exist-sim800c", 9600) }
    error = assert_raises(Sim800c::Error) { @reactor.call(timeout: 5) { @reactor.await(missing.open) } }
    assert_match(/no such device/, error.message)
  end

  def test_close_is_clean_and_writes_fail_afterwards
    open_transport
    @reactor.call(timeout: 2) { @reactor.await(@transport.close) }
    assert_equal :clean, @closed.pop(timeout: 2)
    refute @transport.open?
    error = assert_raises(Sim800c::Error) { @reactor.call(timeout: 2) { @reactor.await(@transport.write("AT\r")) } }
    assert_match(/not open/, error.message)
  end

  def test_lists_serial_ports
    assert_kind_of Array, Sim800c::Transport::Serial.list
  end
end

# MODEM_DRIVER=tcp through the serial bridge, with the simulator standing in for the serial port.
class BridgeTest < Minitest::Test
  include ModemStackHelpers

  def setup
    @config = modem_config
    @bridge_reactor = Sim800c::Reactor.new(name: "bridge").start
    @sim = @bridge_reactor.call(timeout: 2) { Sim800c::Transport::Simulator.new(@bridge_reactor, time_scale: 0.05) }
    @bridge = Sim800c::Bridge.start(@sim, host: "127.0.0.1", port: 0, reopen: 0.1)
    @reactor = Sim800c::Reactor.new.start
    @events = RecordingEvents.new
  end

  def teardown
    @reactor.call(timeout: 5) { @manager&.stop }
    @reactor.stop
    @bridge.close
    @bridge_reactor.stop
  end

  def start_manager(port)
    @config.modem.driver = :tcp
    @config.modem.tcp_host = "127.0.0.1"
    @config.modem.tcp_port = port
    @manager = @reactor.call(timeout: 2) do
      transport = Sim800c::Transport::Tcp.new(@reactor, "127.0.0.1", port)
      Sim800c::ModemManager.new(transport, reactor: @reactor, config: @config.modem, sms_config: @config.sms,
                                           events: @events).tap(&:start)
    end
  end

  def test_operates_the_modem_over_tcp
    start_manager(@bridge.port)
    wait_for(5, "ready over tcp") { @reactor.call(timeout: 5) { @manager.can_operate? } }
    assert_match(%r{\Atcp://127\.0\.0\.1:\d+\z}, @reactor.call(timeout: 2) { @manager.status[:port] })
    res = @reactor.call(timeout: 5) { @manager.modem.raw("AT+CSQ") }
    assert_match(/\A\+CSQ: \d+,0\z/, res.lines[0])
  end

  def test_reconnects_after_the_modem_is_unplugged_from_the_bridge_host
    start_manager(@bridge.port)
    wait_for(5, "ready over tcp") { @reactor.call(timeout: 5) { @manager.can_operate? } }
    @bridge_reactor.call(timeout: 2) { @sim.unplug(0.6) }
    wait_for(2, "disconnect seen through the bridge") { @reactor.call(timeout: 5) { @manager.status[:connection] } != "ready" }
    wait_for(10, "reconnected through the bridge") { @reactor.call(timeout: 5) { @manager.can_operate? } }
  end

  def test_reports_an_unreachable_bridge_clearly
    start_manager(1)
    wait_for(3, "connection error") { @reactor.call(timeout: 5) { @manager.status[:last_error] } }
    assert_match(%r{Cannot reach serial bridge at tcp://127\.0\.0\.1:1}, @reactor.call(timeout: 2) { @manager.status[:last_error] })
  end

  def test_the_newest_client_wins
    first = TCPSocket.new("127.0.0.1", @bridge.port)
    second = TCPSocket.new("127.0.0.1", @bridge.port)
    wait_for(2, "first client dropped") do
      first.read_nonblock(10, exception: false).nil?
    rescue IOError, SystemCallError
      true
    end
    second.write("AT\r")
    assert_match(/OK/, wait_for(2, "reply") { second.read_nonblock(100, exception: false).then { |r| r.is_a?(String) && r.include?("OK") ? r : nil } })
  ensure
    first&.close
    second&.close
  end
end

class TcpTransportTest < Minitest::Test
  def test_close_while_opening_does_not_leak_the_connection
    server = TCPServer.new("127.0.0.1", 0)
    reactor = Sim800c::Reactor.new.start
    transport = reactor.call(timeout: 2) { Sim800c::Transport::Tcp.new(reactor, "127.0.0.1", server.local_address.ip_port) }
    error = assert_raises(Sim800c::Error) do
      reactor.call(timeout: 5) do
        opening = transport.open
        reactor.await(transport.close)
        reactor.await(opening)
      end
    end
    assert_match(/closed while opening/, error.message)
    refute transport.open?
    peer = server.accept
    assert_equal "", peer.read # EOF: the client side was closed
  ensure
    peer&.close
    server&.close
    reactor&.stop
  end
end
