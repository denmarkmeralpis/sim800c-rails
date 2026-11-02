# frozen_string_literal: true

require "unit_helper"

class ModemParsingTest < Minitest::Test
  M = Sim800c::Modem

  def test_parse_cusd_reads_the_session_state_and_text
    assert_equal({ state: :done, text: "Balance: P10, valid\nuntil 01-01" },
                 M.parse_cusd("+CUSD: 0,\"Balance: P10, valid\r\nuntil 01-01\",15"))
    assert_equal({ state: :reply, text: "1 Yes\n2 No" }, M.parse_cusd("+CUSD: 1,\"1 Yes\n2 No\",15"))
    assert_equal({ state: :unsupported, text: nil }, M.parse_cusd("+CUSD: 4"))
    assert_equal({ state: :ended, text: nil }, M.parse_cusd("+CUSD: 2"))
    assert_equal({ state: :ended, text: nil }, M.parse_cusd("+CUSD: 9"))
    assert_equal({ state: :ended, text: nil }, M.parse_cusd("+CUSD: -1"))
  end

  def test_parse_cusd_decodes_ucs2_replies_sent_as_hex
    assert_equal "Salamat ✓", M.parse_cusd("+CUSD: 0,\"00530061006C0061006D0061007400202713\",72")[:text]
    # Hex-looking text with a GSM 7-bit DCS is left alone.
    assert_equal "1234", M.parse_cusd("+CUSD: 0,\"1234\",15")[:text]
  end

  def test_parse_clcc
    assert_equal({ id: 1, direction: "outbound", state: "alerting", number: "+639171234567" },
                 M.parse_clcc('+CLCC: 1,0,3,0,0,"+639171234567",145,""'))
    assert_equal({ id: 2, direction: "inbound", state: "incoming", number: nil }, M.parse_clcc('+CLCC: 2,1,4,0,0,"",129,""'))
    assert_nil M.parse_clcc('+CLCC: 1,0,0,1,0,"123",129') # data call
    assert_equal "disconnected", M.parse_clcc('+CLCC: 1,0,9,0,0,"1",129')[:state]
  end

  def test_split_params_honours_quotes
    assert_equal ["0", "0", "Globe, Inc"], M.split_params('0,0,"Globe, Inc"')
  end

  def test_signal_and_registration
    assert_equal({ rssi: 20, dbm: -73, percent: 65, ber: 0, quality: "excellent" }, M.signal_from(20, 0))
    assert_equal "unknown", M.signal_from(99, 99)[:quality]
    assert_equal "poor", M.signal_from(5, 99)[:quality]
    assert_nil M.signal_from(5, 99)[:ber]
    assert_equal "roaming", M.registration_from(5)
    assert_equal "unknown", M.registration_from(-1)
    assert_equal "unknown", M.registration_from(nil)
  end

  def test_sim_states
    assert_equal "ready", M.sim_state_from("READY")[:state]
    assert_equal "pin_required", M.sim_state_from("SIM PIN")[:state]
    assert_equal({ state: "error", detail: "WEIRD" }, M.sim_state_from("WEIRD"))
  end
end

class PhoneTest < Minitest::Test
  P = Sim800c::Phone

  def test_normalizes_phone_numbers
    assert_equal "+639171234567", P.normalize(" +63 917 123-4567 ")
    assert_equal "09171234567", P.normalize("(0917) 123.4567")
    error = assert_raises(Sim800c::AppError) { P.normalize("12;ATH") }
    assert_equal [400, "bad_request"], [error.status, error.code]
    assert_match(/Invalid phone number/, error.message)
  end

  def test_dial_strings_and_ussd_codes
    assert_equal "*123#", P.normalize_dial_string("*123#")
    assert P.ussd_code?("*143*2#")
    refute P.ussd_code?("09171234567")
    assert_equal "*123#", P.normalize_ussd_code(" *123# ")
    assert_raises(Sim800c::AppError) { P.normalize_ussd_code('*1"#') }
  end

  def test_phones_match_on_the_trailing_digits
    assert P.match?("09171234567", "+639171234567")
    refute P.match?("09171234567", "+639171234568")
    assert P.match?("INFO", "INFO")
  end
end
