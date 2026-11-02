# frozen_string_literal: true

require "unit_helper"
require "support/fake_transport"

class AtClientTest < Minitest::Test
  def setup
    @reactor = Sim800c::Reactor.new.start
  end

  def teardown
    @reactor.stop
  end

  # Builds a client on the reactor and runs the block in a reactor task with (transport, client, urcs).
  def with_client(timeout: 0.5, &block)
    @reactor.call(timeout: 5) do
      t = FakeTransport.new(@reactor)
      at = Sim800c::AT::Client.new(t, reactor: @reactor, default_timeout: timeout)
      urcs = []
      at.on(:urc) { |u| urcs << u }
      block.call(t, at, urcs)
    end
  end

  def later(seconds, &block) = @reactor.after(seconds, &block)

  def test_collects_response_lines_ignores_echo_and_resolves_on_ok
    res = with_client do |t, at|
      t.on_write = ->(d) { t.feed("AT+CSQ\r\r\n+CSQ: 18,0\r\n\r\nOK\r\n") if d == "AT+CSQ\r" }
      at.command("AT+CSQ", expect: ["+CSQ:"])
    end
    assert_equal ["+CSQ: 18,0"], res.lines
    assert_equal "OK", res.final
  end

  def test_reassembles_lines_split_across_chunks
    res = with_client do |t, at|
      t.on_write = lambda do |_d|
        t.feed("\r\n+COPS: 0,0,\"Glo")
        later(0.005) { t.feed("be\"\r\n\r\nO") }
        later(0.01) { t.feed("K\r\n") }
      end
      at.command("AT+COPS?", expect: ["+COPS:"])
    end
    assert_equal ["+COPS: 0,0,\"Globe\""], res.lines
  end

  def test_routes_urcs_that_arrive_mid_command_to_the_urc_stream
    res, urcs = with_client do |t, at, urcs|
      t.on_write = ->(_d) { t.feed("\r\n+CMTI: \"SM\",3\r\n\r\nRING\r\n\r\n+CSQ: 20,0\r\n\r\nOK\r\n") }
      [at.command("AT+CSQ", expect: ["+CSQ:"]), urcs]
    end
    assert_equal ["+CSQ: 20,0"], res.lines
    assert_equal ["+CMTI: \"SM\",3", "RING"], urcs.map(&:line)
  end

  def test_treats_urc_like_lines_as_response_when_the_command_expects_them
    res, urcs = with_client do |t, at, urcs|
      t.on_write = ->(_d) { t.feed("\r\n+CPIN: READY\r\n\r\nOK\r\n") }
      res = at.command("AT+CPIN?", expect: ["+CPIN:"])
      assert_empty urcs
      t.feed("\r\n+CPIN: NOT INSERTED\r\n")
      [res, urcs]
    end
    assert_equal ["+CPIN: READY"], res.lines
    assert_equal ["+CPIN: NOT INSERTED"], urcs.map(&:line)
  end

  def test_writes_the_payload_after_the_prompt_for_cmgs
    res, writes = with_client do |t, at|
      t.on_write = lambda do |d|
        if d == "AT+CMGS=18\r"
          t.feed("\r\n> ")
        elsif d.end_with?("\x1a")
          t.feed("\r\n+CMGS: 42\r\n\r\nOK\r\n")
        end
      end
      [at.command("AT+CMGS=18", payload: "0011000B91", expect: ["+CMGS:"]), t.writes]
    end
    assert_equal ["+CMGS: 42"], res.lines
    assert_equal "0011000B91\x1a", writes[1]
  end

  def test_rejects_with_decoded_cms_error_codes
    error = with_client do |t, at|
      t.on_write = ->(d) { t.feed("\r\n+CMS ERROR: 331\r\n") if d.start_with?("AT+CMGS") }
      at.command("AT+CMGS=10", payload: "00")
    rescue Sim800c::AT::CommandError => e
      e
    end
    assert_equal :cms, error.kind
    assert_equal 331, error.code
    assert_match(/No network service/, error.message)
  end

  def test_times_out_aborts_the_sms_prompt_and_continues_with_the_next_command
    first, second, timeouts, writes = with_client(timeout: 0.1) do |t, at|
      timeouts = 0
      at.on(:timeout) { timeouts += 1 }
      t.on_write = ->(d) { t.feed("\r\nOK\r\n") if d == "AT\r" }
      first = at.execute("AT+CMGS=10", payload: "00")
      second = at.execute("AT")
      error = begin
        @reactor.await(first)
      rescue Sim800c::AT::CommandError => e
        e
      end
      [error, @reactor.await(second), timeouts, t.writes]
    end
    assert_equal :timeout, first.kind
    assert_equal "OK", second.final
    assert_equal 1, timeouts
    assert_includes writes, "\e", "ESC sent to abort the prompt"
  end

  def test_accepts_custom_final_result_codes
    res, urcs = with_client do |t, at, urcs|
      t.on_write = ->(_d) { t.feed("\r\nBUSY\r\n") }
      [at.command("ATD123;", final_codes: ["BUSY", "NO CARRIER"]), urcs]
    end
    assert_equal "BUSY", res.final
    assert_empty urcs
  end

  def test_emits_two_line_urcs_with_their_pdu_payload
    urcs = with_client do |t, _at, urcs|
      t.feed("\r\n+CDS: 25\r\n0006110B919")
      t.feed("671214365F7\r\n")
      @reactor.sleep(0.005)
      urcs
    end
    assert_equal [Sim800c::AT::Urc.new(line: "+CDS: 25", data: "0006110B919671214365F7")], urcs
  end

  def test_keeps_line_breaks_inside_a_ussd_menu_as_one_urc
    urcs = with_client do |t, at, urcs|
      t.on_write = ->(_d) { t.feed("\r\nOK\r\n") }
      at.command("AT+CUSD=1,\"*143#\",15")
      t.feed("\r\n+CUSD: 1,\"Services\n1 Bal")
      t.feed("ance\r\n2 Promos\",15\r\n\r\n+CMTI: \"SM\",1\r\n")
      @reactor.sleep(0.005)
      assert_equal ["+CUSD: 1,\"Services\n1 Balance\r\n2 Promos\",15", "+CMTI: \"SM\",1"], urcs.map(&:line)
      t.feed("\r\n+CUSD: 4\r\n")
      urcs
    end
    assert_equal "+CUSD: 4", urcs[2]&.line
  end

  def test_runs_higher_priority_commands_first
    order = with_client do |t, at|
      order = []
      t.on_write = lambda do |d|
        order << d.strip
        later(0.005) { t.feed("\r\nOK\r\n") }
      end
      promises = [at.execute("AT+CSQ"), at.execute("AT+CREG?"), at.execute("ATH", priority: 10)]
      promises.each { |p| @reactor.await(p) }
      order
    end
    assert_equal ["AT+CSQ", "ATH", "AT+CREG?"], order
  end

  def test_fails_everything_pending_on_disconnect_and_refuses_control_characters
    errors = with_client do |_t, at|
      p1 = at.execute("AT")
      p2 = at.execute("AT+CSQ")
      at.fail_all("unplugged")
      bad = at.execute("AT\rATD123;")
      [p1, p2, bad].map(&:reason)
    end
    assert_equal %i[disconnected disconnected], errors[0, 2].map(&:kind)
    assert_match(/Invalid characters/, errors[2].message)
  end

  def test_fails_commands_when_the_transport_is_closed
    error = with_client do |t, at|
      t.opened = false
      @reactor.await(at.execute("AT")) rescue $! # rubocop:disable Style/RescueModifier
    end
    assert_equal :disconnected, error.kind
    assert_match(/not connected/, error.message)
  end

  def test_keeps_a_bounded_traffic_log
    traffic = with_client do |t, at|
      t.on_write = ->(_d) { t.feed("\r\nOK\r\n") }
      200.times { at.command("AT") }
      at.traffic
    end
    assert_equal 300, traffic.size
    assert_equal %w[tx rx], traffic.last(2).map { |e| e[:dir] }
  end
end

class AtErrorsTest < Minitest::Test
  E = Sim800c::AT

  def test_parses_error_lines
    assert_equal :error, E.parse_error_line("ERROR").kind
    cme = E.parse_error_line("+CME ERROR: 10")
    assert_equal [:cme, 10, "SIM not inserted (CME 10)"], [cme.kind, cme.code, cme.message]
    assert_equal "operation not allowed", E.parse_error_line("+CME ERROR: operation not allowed").message
    assert_nil E.parse_error_line("OK")
  end

  def test_classifies_retryable_sms_errors
    refute E.retryable_sms_error?(E::CommandError.new(:cms, "AT+CMGS", "x", 1))
    assert E.retryable_sms_error?(E::CommandError.new(:cms, "AT+CMGS", "x", 42))
    assert E.retryable_sms_error?(E::CommandError.new(:timeout, "AT+CMGS", "x"))
    assert E.retryable_sms_error?(RuntimeError.new("other"))
  end
end
