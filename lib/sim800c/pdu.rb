# frozen_string_literal: true

module Sim800c
  # SMS PDU codec (3GPP TS 23.040): SMS-SUBMIT encoding, SMS-DELIVER / SMS-STATUS-REPORT /
  # SMS-SUBMIT decoding, concatenated (multipart) messages, GSM 7-bit and UCS-2.
  module PDU
    class Error < Sim800c::Error; end
  end
end

require_relative "pdu/gsm7"

module Sim800c
  module PDU
    ConcatInfo = Data.define(:ref, :total, :seq)

    # encoding: "gsm7" or "ucs2"; units: septets for GSM 7-bit, UTF-16 code units for UCS-2.
    MessagePlan = Data.define(:encoding, :parts, :units)

    # pdu: hex including the (empty) SMSC prefix, ready for AT+CMGS; tpdu_length: its argument.
    EncodedPart = Data.define(:pdu, :tpdu_length)

    Submission = Data.define(:encoding, :parts)

    Deliver = Data.define(:smsc, :sender, :sender_type, :timestamp, :encoding, :text, :concat) do
      def type = :deliver
    end

    Submit = Data.define(:smsc, :reference, :recipient, :status_report, :encoding, :text, :concat) do
      def type = :submit
    end

    StatusReport = Data.define(:smsc, :reference, :recipient, :submitted_at, :discharged_at, :status, :state,
                               :status_text) do
      def type = :status_report
    end

    LIMITS = {
      "gsm7" => { single: 160, multi: 153 }, # septets; 7 septets go to the concat UDH
      "ucs2" => { single: 70, multi: 67 }    # UTF-16 code units; 6 octets go to the UDH
    }.freeze

    DELIVERY_STATUS_TEXT = {
      0x00 => "Delivered to recipient",
      0x01 => "Forwarded, delivery unconfirmed",
      0x02 => "Replaced by the service centre",
      0x20 => "Network congestion",
      0x21 => "Recipient busy",
      0x22 => "No response from recipient",
      0x23 => "Service rejected",
      0x24 => "Quality of service not available",
      0x25 => "Error in recipient handset",
      0x40 => "Remote procedure error",
      0x41 => "Incompatible destination",
      0x42 => "Connection rejected by recipient",
      0x43 => "Recipient not obtainable",
      0x44 => "Quality of service not available",
      0x45 => "No interworking available",
      0x46 => "Validity period expired",
      0x47 => "Deleted by sender",
      0x48 => "Deleted by service centre",
      0x49 => "Message does not exist"
    }.freeze

    SEMI_OCTET_CHARS = "0123456789*#abc"
    private_constant :SEMI_OCTET_CHARS

    module_function

    # ---------------------------------------------------------------------------------------------
    # Message planning (encoding selection + segmentation)
    # ---------------------------------------------------------------------------------------------

    # Picks an encoding and splits text into segments without breaking escape sequences or
    # surrogate pairs.
    def plan_message(text)
      encoding = GSM7.gsm7?(text) ? "gsm7" : "ucs2"
      unit_length = encoding == "gsm7" ? ->(ch) { GSM7.char_length(ch) } : ->(ch) { ch.ord > 0xffff ? 2 : 1 }

      units = text.each_char.sum { |ch| unit_length.call(ch) }
      limits = LIMITS.fetch(encoding)
      return MessagePlan.new(encoding: encoding, parts: [text], units: units) if units <= limits[:single]

      parts = []
      current = +""
      current_length = 0
      text.each_char do |ch|
        length = unit_length.call(ch)
        if current_length + length > limits[:multi]
          parts << current
          current = +""
          current_length = 0
        end
        current << ch
        current_length += length
      end
      parts << current unless current.empty?
      MessagePlan.new(encoding: encoding, parts: parts, units: units)
    end

    # ---------------------------------------------------------------------------------------------
    # Encoding
    # ---------------------------------------------------------------------------------------------

    # reference: concatenation reference (0-255) shared by all parts of one message.
    # validity: relative validity period octet (TS 23.040 9.2.3.12.1); 0xAA = 4 days.
    def encode_submit(to:, text:, status_report: false, reference: 0, max_parts: nil, validity: 0xaa)
      plan = plan_message(text)
      if max_parts && plan.parts.size > max_parts
        raise Error, "Message too long: needs #{plan.parts.size} parts (max #{max_parts})"
      end

      da = encode_address(to)
      total = plan.parts.size
      ref = reference.to_i & 0xff

      parts = plan.parts.each_with_index.map do |part, i|
        udh = total > 1 ? concat_udh(ref, total, i + 1) : nil
        udl, ud = build_user_data(plan.encoding, part, udh)
        first_octet = 0x01 | 0x10 # SMS-SUBMIT, relative validity period present
        first_octet |= 0x20 if status_report
        first_octet |= 0x40 if udh
        tpdu = [first_octet, 0x00].pack("C*") + # TP-MR assigned by the modem
               da + [0x00, dcs_for(plan.encoding), validity, udl].pack("C*") + ud
        EncodedPart.new(pdu: "00#{hex(tpdu)}", tpdu_length: tpdu.bytesize)
      end
      Submission.new(encoding: plan.encoding, parts: parts)
    end

    # Builds SMS-DELIVER PDUs as a network would hand them to the modem (simulator and tests).
    def encode_deliver(from:, text:, timestamp: Time.now, smsc: nil, reference: 0)
      plan = plan_message(text)
      oa = from.match?(/\A\+?[0-9*#]+\z/) ? encode_address(from) : encode_alphanumeric_address(from)
      smsc_bytes = smsc ? encode_smsc(smsc) : "\x00".b
      scts = encode_timestamp(timestamp)
      total = plan.parts.size
      ref = reference.to_i & 0xff

      plan.parts.each_with_index.map do |part, i|
        udh = total > 1 ? concat_udh(ref, total, i + 1) : nil
        udl, ud = build_user_data(plan.encoding, part, udh)
        first_octet = 0x04 | (udh ? 0x40 : 0) # SMS-DELIVER, no more messages waiting
        tpdu = [first_octet].pack("C") + oa + [0x00, dcs_for(plan.encoding)].pack("C*") + scts + [udl].pack("C") + ud
        EncodedPart.new(pdu: hex(smsc_bytes + tpdu), tpdu_length: tpdu.bytesize)
      end
    end

    def encode_status_report(reference:, recipient:, status:, submitted_at:, discharged_at:)
      tpdu = [0x06, reference & 0xff].pack("C*") + # SMS-STATUS-REPORT
             encode_address(recipient) + encode_timestamp(submitted_at) + encode_timestamp(discharged_at) +
             [status & 0xff].pack("C")
      EncodedPart.new(pdu: "00#{hex(tpdu)}", tpdu_length: tpdu.bytesize)
    end

    def encode_address(number)
      n = number.to_s.gsub(/[\s\-().]/, "")
      toa = 0x81
      if n.start_with?("+")
        toa = 0x91
        n = n[1..]
      end
      raise Error, "Invalid phone number: #{number}" unless n.match?(/\A[0-9*#]{1,20}\z/)

      [n.size, toa].pack("C*") + semi_octets(n)
    end

    # ---------------------------------------------------------------------------------------------
    # Decoding
    # ---------------------------------------------------------------------------------------------

    # Decodes a hex PDU. `tpdu_length` (as reported by +CMGR / +CMGL / +CDS) detects PDUs that omit
    # the SMSC prefix, which some firmware does for status reports.
    def decode(hex_pdu, tpdu_length = nil)
      clean = hex_pdu.to_s.strip
      raise Error, "PDU is not valid hex" unless clean.match?(/\A(?:[0-9a-fA-F]{2})+\z/)

      bytes = [clean].pack("H*").bytes
      r = Reader.new(bytes)
      smsc = tpdu_length && bytes.size == tpdu_length ? nil : read_smsc(r)

      first_octet = r.byte
      mti = first_octet & 0x03
      udhi = first_octet.anybits?(0x40)

      case mti
      when 0
        oa = read_address(r)
        r.byte # TP-PID
        dcs = r.byte
        timestamp = read_timestamp(r)
        encoding, text, concat = read_user_data(r, dcs, udhi)
        Deliver.new(smsc: smsc, sender: oa[0], sender_type: oa[1], timestamp: timestamp, encoding: encoding,
                    text: text, concat: concat)
      when 1
        reference = r.byte
        da = read_address(r)
        r.byte # TP-PID
        dcs = r.byte
        vpf = (first_octet >> 3) & 0x03
        if vpf == 0b10
          r.byte
        elsif vpf != 0
          r.bytes(7)
        end
        encoding, text, concat = read_user_data(r, dcs, udhi)
        Submit.new(smsc: smsc, reference: reference, recipient: da[0], status_report: first_octet.anybits?(0x20),
                   encoding: encoding, text: text, concat: concat)
      when 2
        reference = r.byte
        ra = read_address(r)
        submitted_at = read_timestamp(r)
        discharged_at = read_timestamp(r)
        status = r.byte
        described = describe_delivery_status(status)
        StatusReport.new(smsc: smsc, reference: reference, recipient: ra[0], submitted_at: submitted_at,
                         discharged_at: discharged_at, status: status, state: described[:state],
                         status_text: described[:status_text])
      else
        raise Error, "Unsupported PDU type (MTI=#{mti})"
      end
    end

    def dcs_encoding(dcs)
      group = dcs >> 4
      if group <= 0x7 # general data coding / automatic deletion groups
        alphabet = (dcs >> 2) & 0x03
        return "8bit" if alphabet == 1
        return "ucs2" if alphabet == 2

        return "gsm7"
      end
      return "ucs2" if group == 0xe
      return(dcs.anybits?(0x04) ? "8bit" : "gsm7") if group == 0xf

      "gsm7"
    end

    # { state: "delivered" | "pending" | "failed", status_text: }
    def describe_delivery_status(status)
      if status < 0x20
        return { state: "delivered", status_text: DELIVERY_STATUS_TEXT[status] || "Delivered" }
      end
      if status < 0x40
        return { state: "pending", status_text: DELIVERY_STATUS_TEXT[status] || "Temporary error, retrying" }
      end

      text = DELIVERY_STATUS_TEXT[status] || DELIVERY_STATUS_TEXT[status - 0x40] || "Permanent delivery failure"
      text = "#{DELIVERY_STATUS_TEXT[status - 0x40] || 'Temporary error'} (gave up)" if status >= 0x60
      { state: "failed", status_text: text }
    end

    # Reads a byte array, raising PDU::Error when it runs out.
    class Reader
      def initialize(bytes)
        @bytes = bytes
        @pos = 0
      end

      def byte
        raise Error, "PDU is truncated" if @pos >= @bytes.size

        b = @bytes[@pos]
        @pos += 1
        b
      end

      def bytes(count)
        raise Error, "PDU is truncated" if @pos + count > @bytes.size

        out = @bytes[@pos, count]
        @pos += count
        out
      end

      def rest
        @bytes[@pos..] || []
      end
    end
    private_constant :Reader

    # Private helpers (module_function makes copies; keep them out of the public API).

    def hex(binary) = binary.unpack1("H*").upcase

    def dcs_for(encoding) = encoding == "ucs2" ? 0x08 : 0x00

    def concat_udh(ref, total, seq) = [0x05, 0x00, 0x03, ref & 0xff, total, seq].pack("C*")

    def build_user_data(encoding, text, udh)
      if encoding == "gsm7"
        septets = GSM7.to_septets(text)
        return [septets.size, GSM7.pack_septets(septets)] unless udh

        header_bits = udh.bytesize * 8
        fill = (7 - (header_bits % 7)) % 7
        header_septets = (header_bits + fill) / 7
        return [header_septets + septets.size, udh + GSM7.pack_septets(septets, fill)]
      end
      body = text.encode(Encoding::UTF_16BE).b
      ud = udh ? udh + body : body
      [ud.bytesize, ud]
    end

    def nibble(ch)
      return ch.ord - 48 if ch.between?("0", "9")
      return 0x0a if ch == "*"
      return 0x0b if ch == "#"

      0x0f
    end

    def semi_octets(digits)
      d = digits.size.odd? ? "#{digits}F" : digits
      d.chars.each_slice(2).map { |lo, hi| (nibble(hi) << 4) | nibble(lo) }.pack("C*")
    end

    def encode_alphanumeric_address(text)
      septets = GSM7.to_septets(text[0, 11])
      [((septets.size * 7) + 3) / 4, 0xd0].pack("C*") + GSM7.pack_septets(septets)
    end

    def encode_smsc(number)
      addr = encode_address(number)
      # SMSC length counts octets (type + digits), unlike TP addresses which count digits.
      [addr.bytesize - 1].pack("C") + addr.byteslice(1..)
    end

    def encode_timestamp(time)
      t = time.utc
      sw = ->(n) { ((n % 10) << 4) | (n / 10) }
      [sw.call(t.year % 100), sw.call(t.month), sw.call(t.day), sw.call(t.hour), sw.call(t.min), sw.call(t.sec),
       0x00].pack("C*") # UTC
    end

    def decode_semi_octets(bytes, digits)
      s = +""
      bytes.each do |byte|
        [byte & 0x0f, byte >> 4].each do |n|
          return s if s.size >= digits || n == 0x0f

          s << SEMI_OCTET_CHARS[n]
        end
      end
      s
    end

    def read_smsc(r)
      length = r.byte
      return nil if length.zero?

      toa = r.byte
      digits = decode_semi_octets(r.bytes(length - 1), (length - 1) * 2)
      return nil if digits.empty?

      ((toa >> 4) & 0x07) == 0b001 ? "+#{digits}" : digits
    end

    # [number, type]
    def read_address(r)
      length = r.byte
      toa = r.byte
      data = r.bytes((length + 1) / 2)
      ton = (toa >> 4) & 0x07
      return [GSM7.from_septets(GSM7.unpack_septets(data, (length * 4) / 7)), "alphanumeric"] if ton == 0b101

      digits = decode_semi_octets(data, length)
      return ["+#{digits}", "international"] if ton == 0b001

      [digits, ton == 0b010 ? "national" : "unknown"]
    end

    # Out-of-range fields roll over (like JavaScript's Date.UTC) instead of raising.
    def read_timestamp(r)
      b = r.bytes(7)
      d = ->(x) { ((x & 0x0f) * 10) + (x >> 4) }
      tz = b[6]
      quarters = (((tz & 0x07) * 10) + (tz >> 4)) * (tz.anybits?(0x08) ? -1 : 1)
      month_index = d.call(b[1]) - 1
      year = 2000 + d.call(b[0]) + month_index.div(12)
      base = Time.utc(year, month_index.modulo(12) + 1, 1)
      seconds = ((d.call(b[2]) - 1) * 86_400) + (d.call(b[3]) * 3600) + (d.call(b[4]) * 60) + d.call(b[5])
      base + seconds - (quarters * 15 * 60)
    end

    def parse_udh(udh)
      concat = nil
      i = 0
      while i + 2 <= udh.size
        iei = udh[i]
        length = udh[i + 1]
        data = udh[i + 2, length] || []
        if data.size == length
          if iei == 0x00 && length == 3
            concat = ConcatInfo.new(ref: data[0], total: data[1], seq: data[2])
          elsif iei == 0x08 && length == 4
            concat = ConcatInfo.new(ref: (data[0] << 8) | data[1], total: data[2], seq: data[3])
          end
        end
        i += 2 + length
      end
      concat && concat.total.positive? && concat.seq.positive? ? concat : nil
    end

    def decode_ucs2(bytes)
      even = bytes[0, bytes.size & ~1] || []
      even.pack("C*").force_encoding(Encoding::UTF_16BE)
          .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
    end

    # [encoding, text, concat]
    def read_user_data(r, dcs, udhi)
      udl = r.byte
      encoding = dcs_encoding(dcs)
      rest = r.rest
      concat = nil

      if encoding == "gsm7"
        ud = rest[0, ((udl * 7) + 7) / 8] || []
        start_septet = 0
        if udhi && !ud.empty?
          udhl = ud[0]
          concat = parse_udh(ud[1, udhl] || [])
          start_septet = (((udhl + 1) * 8) + 6) / 7
        end
        text = GSM7.from_septets(GSM7.unpack_septets(ud, [0, udl - start_septet].max, start_septet * 7))
      else
        ud = rest[0, udl] || []
        body = ud
        if udhi && !ud.empty?
          udhl = ud[0]
          concat = parse_udh(ud[1, udhl] || [])
          body = ud[(1 + udhl)..] || []
        end
        text = encoding == "ucs2" ? decode_ucs2(body) : "[binary #{body.size} bytes] #{body.pack('C*').unpack1('H*')}"
      end
      [encoding, text, concat]
    end

    private_class_method :hex, :dcs_for, :concat_udh, :build_user_data, :nibble, :semi_octets,
                         :encode_alphanumeric_address, :encode_smsc, :encode_timestamp, :decode_semi_octets,
                         :read_smsc, :read_address, :read_timestamp, :parse_udh, :decode_ucs2, :read_user_data
  end
end
