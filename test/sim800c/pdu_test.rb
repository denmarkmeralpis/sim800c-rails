# frozen_string_literal: true

require "unit_helper"

class Gsm7Test < Minitest::Test
  G = Sim800c::PDU::GSM7

  def test_has_128_basic_characters
    assert_equal 128, G::ALPHABET_SIZE
    assert_equal "@", G::BASIC[0]
    assert_equal "\e", G::BASIC[27]
    assert_equal " ", G::BASIC[32]
    assert_equal "¡", G::BASIC[64]
    assert_equal "à", G::BASIC[127]
  end

  def test_packs_hellohello_to_the_reference_octets
    assert_equal "E8329BFD4697D9EC37", G.pack_septets(G.to_septets("hellohello")).unpack1("H*").upcase
  end

  def test_round_trips_extension_characters_through_escape_sequences
    text = "Price: 10€ [ok] {x} ~^|\\"
    septets = G.to_septets(text)
    assert_equal text, G.from_septets(G.unpack_septets(G.pack_septets(septets), septets.size))
  end

  def test_detects_non_gsm_characters
    assert G.gsm7?("Hello @ £5")
    refute G.gsm7?("Kumusta 👋")
    refute G.gsm7?("Привет")
  end
end

class MessagePlanningTest < Minitest::Test
  P = Sim800c::PDU

  def test_keeps_160_gsm_characters_in_one_part
    plan = P.plan_message("a" * 160)
    assert_equal "gsm7", plan.encoding
    assert_equal 1, plan.parts.size
  end

  def test_splits_161_gsm_characters_into_153_and_8
    assert_equal [153, 8], P.plan_message("a" * 161).parts.map(&:size)
  end

  def test_counts_extension_characters_as_two_septets_and_never_splits_them
    plan = P.plan_message(("a" * 152) + "€" + ("b" * 10))
    assert_equal "a" * 152, plan.parts[0]
    assert plan.parts[1].start_with?("€")
  end

  def test_uses_ucs2_with_70_67_limits_and_does_not_split_surrogate_pairs
    assert_equal "ucs2", P.plan_message(("ñ" * 10) + "😀").encoding
    plan = P.plan_message(("x" * 66) + "😀" + ("y" * 10))
    assert_equal 2, plan.parts.size
    assert_equal "x" * 66, plan.parts[0]
    assert plan.parts[1].start_with?("😀")
  end

  def test_counts_units_like_utf16
    assert_equal 2, P.plan_message("😀").units
    assert_equal 2, P.plan_message("€").units
  end
end

class PduDecodingTest < Minitest::Test
  P = Sim800c::PDU

  def test_decodes_the_reference_sms_deliver
    pdu = P.decode("07917283010010F5040BC87238880900F10000993092516195800AE8329BFD4697D9EC37")
    assert_equal :deliver, pdu.type
    assert_equal "+27381000015", pdu.smsc
    assert_equal "27838890001", pdu.sender
    assert_equal "hellohello", pdu.text
    assert_equal "gsm7", pdu.encoding
    # "99-03-29 15:16:59 GMT+2" — two-digit years are interpreted as 20xx
    assert_equal "2099-03-29T13:16:59.000Z", Sim800c.iso(pdu.timestamp)
  end

  def test_rejects_malformed_pdus
    assert_raises(Sim800c::PDU::Error) { P.decode("ZZ") }
    assert_raises(Sim800c::PDU::Error) { P.decode("0791") }
  end

  def test_tolerates_out_of_range_timestamp_fields_like_javascript
    # Month 13 rolls over into the next year instead of raising.
    deliver = P.encode_deliver(from: "+639170000001", text: "x", timestamp: Time.utc(2026, 1, 1)).first
    bytes = [deliver.pdu].pack("H*").bytes
    scts = bytes.size - 7 - 2 # 7 timestamp octets, then UDL + 1 octet of text
    bytes[scts + 1] = 0x31 # month "13"
    decoded = P.decode(bytes.pack("C*").unpack1("H*"))
    assert_equal "2027-01-01T00:00:00.000Z", Sim800c.iso(decoded.timestamp)
  end
end

class PduEncodingTest < Minitest::Test
  P = Sim800c::PDU

  def test_encodes_a_single_part_gsm_message_with_a_status_report_request
    result = P.encode_submit(to: "+639171234567", text: "Hello world", status_report: true)
    assert_equal "gsm7", result.encoding
    assert_equal 1, result.parts.size
    part = result.parts[0]
    assert_equal (part.pdu.size / 2) - 1, part.tpdu_length
    decoded = P.decode(part.pdu)
    assert_equal :submit, decoded.type
    assert_equal "+639171234567", decoded.recipient
    assert_equal "Hello world", decoded.text
    assert decoded.status_report
    assert_nil decoded.concat
  end

  def test_encodes_national_numbers_with_an_odd_digit_count
    parts = P.encode_submit(to: "09171234567", text: "x").parts
    assert_equal "09171234567", P.decode(parts[0].pdu).recipient
  end

  def test_encodes_and_reassembles_a_multipart_gsm_message
    text = ("The quick brown fox jumps over the lazy dog. " * 8).strip
    parts = P.encode_submit(to: "+15551234567", text: text, reference: 42).parts
    assert_equal 3, parts.size
    decoded = parts.map { |p| P.decode(p.pdu) }
    decoded.each_with_index do |d, i|
      assert_equal Sim800c::PDU::ConcatInfo.new(ref: 42, total: 3, seq: i + 1), d.concat
    end
    assert_equal text, decoded.map(&:text).join
  end

  def test_encodes_and_reassembles_a_multipart_ucs2_message
    text = "Magandang umaga po! 🌞 " * 6
    result = P.encode_submit(to: "+639171234567", text: text, reference: 7)
    assert_equal "ucs2", result.encoding
    assert_operator result.parts.size, :>, 1
    assert_equal text, result.parts.map { |p| P.decode(p.pdu).text }.join
  end

  def test_enforces_the_maximum_number_of_parts
    error = assert_raises(Sim800c::PDU::Error) { P.encode_submit(to: "123", text: "a" * 500, max_parts: 3) }
    assert_match(/too long/, error.message)
  end

  def test_rejects_invalid_recipients
    %w[abc 123;ATH].each do |to|
      error = assert_raises(Sim800c::PDU::Error) { P.encode_submit(to: to, text: "x") }
      assert_match(/Invalid phone number/, error.message)
    end
  end

  def test_round_trips_sms_deliver_with_smsc_alphanumeric_sender_and_concatenation
    ts = Time.utc(2026, 10, 30, 8, 15, 30)
    text = "Your OTP is 123456. " + ("Do not share it with anyone. " * 6)
    pdus = P.encode_deliver(from: "MyBank", text: text, timestamp: ts, smsc: "+639170000130", reference: 200)
    assert_equal 2, pdus.size
    decoded = pdus.map { |p| P.decode(p.pdu, p.tpdu_length) }
    assert_equal "MyBank", decoded[0].sender
    assert_equal "alphanumeric", decoded[0].sender_type
    assert_equal "+639170000130", decoded[0].smsc
    assert_equal ts, decoded[0].timestamp
    assert_equal Sim800c::PDU::ConcatInfo.new(ref: 200, total: 2, seq: 2), decoded[1].concat
    assert_equal text, decoded.map(&:text).join
  end

  def test_decodes_status_reports_with_and_without_the_smsc_prefix
    report = P.encode_status_report(reference: 17, recipient: "+639171234567", status: 0,
                                    submitted_at: Time.utc(2026, 10, 30, 8), discharged_at: Time.utc(2026, 10, 30, 8, 0, 5))
    [report.pdu, report.pdu[2..]].each do |hex|
      d = P.decode(hex, report.tpdu_length)
      assert_equal :status_report, d.type
      assert_equal 17, d.reference
      assert_equal "+639171234567", d.recipient
      assert_equal "delivered", d.state
    end
    failed = P.encode_status_report(reference: 1, recipient: "123", status: 0x46,
                                    submitted_at: Time.now, discharged_at: Time.now)
    assert_equal "failed", P.decode(failed.pdu).state
  end

  def test_describes_delivery_statuses
    assert_equal({ state: "delivered", status_text: "Delivered to recipient" }, P.describe_delivery_status(0))
    assert_equal "pending", P.describe_delivery_status(0x21)[:state]
    assert_equal "Validity period expired", P.describe_delivery_status(0x46)[:status_text]
    assert_equal "Recipient busy (gave up)", P.describe_delivery_status(0x61)[:status_text]
  end

  def test_decodes_binary_and_ucs2_concatenated_deliveries
    parts = P.encode_deliver(from: "+639171234567", text: "Ünïcödé ✓ " * 10, reference: 9)
    assert_operator parts.size, :>, 1
    assert_equal "Ünïcödé ✓ " * 10, parts.map { |p| P.decode(p.pdu).text }.join
  end
end
