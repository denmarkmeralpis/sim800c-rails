# frozen_string_literal: true

module Sim800c
  # High-level SIM800C operations on top of the AT client, and URCs turned into typed events.
  #
  # Operations are called inside reactor tasks (they await the modem's answer). Emits :event with a
  # Hash whose :type is one of:
  #   :sms_stored {storage, index}       :sms_direct {pdu, length}
  #   :status_report {pdu, length}       :status_report_stored {storage, index}
  #   :ring  :clip {number}  :call_waiting {number}  :clcc {call}  :call_ended {code}
  #   :mo_ring  :mo_connected  :ussd {state, text}  :boot {line}  :sim {state, detail}
  #   :power {line, fatal}  :other {line}
  class Modem
    include Emitter

    CLCC_STATES = %w[active held dialing alerting incoming waiting disconnected].freeze
    CALL_END_CODES = {
      "NO CARRIER" => :no_carrier, "BUSY" => :busy, "NO ANSWER" => :no_answer, "NO DIALTONE" => :no_dialtone
    }.freeze
    CALL_PRIORITY = 10
    # +CUSD <m>: whether the network wants a reply, or why the session ended.
    USSD_STATES = %i[done reply ended other_client unsupported timeout].freeze
    # Printable ASCII without '"', which would end the quoted AT+CUSD string.
    USSD_TEXT = /\A[\x20\x21\x23-\x7e]{1,160}\z/
    REGISTRATION = %w[not_registered home searching denied unknown roaming].freeze

    class << self
      # Splits an AT parameter list, honouring double quotes.
      def split_params(string)
        out = []
        cur = +""
        quoted = false
        string.each_char do |ch|
          if ch == '"'
            quoted = !quoted
          elsif ch == "," && !quoted
            out << cur.strip
            cur = +""
          else
            cur << ch
          end
        end
        out << cur.strip
      end

      # JavaScript Number() for AT parameters: "" is 0, garbage is nil (NaN).
      def number(value)
        return nil if value.nil?

        s = value.to_s.strip
        return 0 if s.empty?
        return Integer(s, 10) if s.match?(/\A[+-]?\d+\z/)
        return Float(s) if s.match?(/\A[+-]?\d*\.\d+\z/)

        nil
      end

      # { id:, direction: "inbound" | "outbound", state:, number: } for voice calls, else nil.
      def parse_clcc(line)
        p = split_params(after(line, "+CLCC:"))
        id, dir, stat, mode = p.first(4).map { |v| number(v) }
        return nil if id.nil? || mode != 0 # voice calls only

        {
          id: id,
          direction: dir == 1 ? "inbound" : "outbound",
          state: (stat.is_a?(Integer) && stat >= 0 && CLCC_STATES[stat]) || "disconnected",
          number: p[5].to_s.empty? ? nil : p[5]
        }
      end

      # { state: one of USSD_STATES, text: String or nil }
      def parse_cusd(line)
        m, str, dcs = split_params(after(line, "+CUSD:"))
        n = number(m)
        state = n.is_a?(Integer) && n.between?(0, USSD_STATES.size - 1) ? USSD_STATES[n] : :ended
        { state: state, text: str.nil? || str.empty? ? nil : decode_ussd_text(str, number(dcs)) }
      end

      def sim_state_from(value)
        case value.to_s.upcase
        when "READY" then { state: "ready", detail: "Ready" }
        when "SIM PIN", "PH_SIM PIN" then { state: "pin_required", detail: "SIM PIN required" }
        when "SIM PUK", "PH_SIM PUK" then { state: "puk_required", detail: "SIM PUK required (SIM locked)" }
        when "NOT INSERTED" then { state: "not_inserted", detail: "SIM card not inserted" }
        when "NOT READY" then { state: "unknown", detail: "SIM not ready" }
        else { state: "error", detail: value }
        end
      end

      def registration_from(stat)
        (stat.is_a?(Integer) && stat >= 0 && REGISTRATION[stat]) || "unknown"
      end

      def signal_from(rssi, ber)
        if !rssi.is_a?(Numeric) || rssi == 99 || rssi.negative? || rssi > 31
          return { rssi: nil, dbm: nil, percent: nil, ber: nil, quality: "unknown" }
        end

        quality = if rssi.zero? then "none"
                  elsif rssi < 10 then "poor"
                  elsif rssi < 15 then "fair"
                  elsif rssi < 20 then "good"
                  else "excellent"
                  end
        { rssi: rssi, dbm: -113 + (2 * rssi), percent: ((rssi / 31.0) * 100).round, ber: ber == 99 ? nil : ber,
          quality: quality }
      end

      def after(line, prefix) = line[prefix.size..].to_s.strip

      private

      # With AT+CSCS="IRA" 7-bit text passes through as-is, but UCS2-coded replies arrive as hex.
      def decode_ussd_text(string, dcs)
        # CBS data coding scheme: 0x11 (UCS2 with language) or general data coding with the UCS2 alphabet.
        ucs2 = dcs.is_a?(Integer) && (dcs == 0x11 || (dcs & 0xcc) == 0x48)
        if ucs2 && string.match?(/\A(?:[0-9A-Fa-f]{4})+\z/)
          return [string].pack("H*").force_encoding(Encoding::UTF_16BE)
                         .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
        end
        string.gsub(/\r\n?/, "\n")
      end
    end

    attr_reader :at

    def initialize(at, storage: "SM", delivery_reports: true, logger: Sim800c.logger)
      @at = at
      @storage = storage
      @delivery_reports = delivery_reports
      @logger = logger
      at.on(:urc) { |urc| on_urc(urc) }
    end

    # Establishes autobaud sync; the SIM800 needs a few "AT"s after power-up.
    def sync(attempts = 8)
      last_error = nil
      attempts.times do
        @at.command("AT", timeout: 1.2)
        return
      rescue AT::CommandError => e
        raise if e.kind == :disconnected

        last_error = e
      end
      raise Error, "Modem did not respond to AT after #{attempts} attempts — check power, wiring (TX/RX/GND) and " \
                   "baud rate#{" (#{last_error.message})" if last_error}"
    end

    # Baseline configuration that does not depend on the SIM.
    def setup
      @at.command("ATE0")
      @at.command("AT+CMEE=1")
      @at.command("AT+CMGF=0")
      optional('AT+CSCS="IRA"')
      optional("AT+CRC=0")
      optional("AT+COLP=0")
      optional("AT+CREG=0")
    end

    # SMS storage, new-message indications and call reporting. Requires a ready SIM.
    def configure_services
      @at.command(%(AT+CPMS="#{@storage}","#{@storage}","#{@storage}"), expect: ["+CPMS:"])
      @at.command("AT+CNMI=2,1,0,#{@delivery_reports ? 1 : 0},0")
      optional("AT+CLIP=1")
      optional("AT+CLCC=1")
      optional("AT+MORING=1")
    end

    def device_info
      value = lambda do |cmd|
        res = @at.command(cmd)
        v = res.lines[0]&.sub(/\ARevision:\s*/i, "")&.strip
        v.nil? || v.empty? ? nil : v
      rescue StandardError
        nil
      end
      { manufacturer: value.call("AT+CGMI"), model: value.call("AT+CGMM"), revision: value.call("AT+CGMR"),
        imei: value.call("AT+GSN") }
    end

    def sim_identity
      iccid = begin
        v = @at.command("AT+CCID").lines[0]&.gsub(/[^0-9A-F]/i, "")
        v.nil? || v.empty? ? nil : v
      rescue StandardError
        nil
      end
      imsi = begin
        v = @at.command("AT+CIMI").lines[0]&.strip
        v.nil? || v.empty? ? nil : v
      rescue StandardError
        nil
      end
      { iccid: iccid, imsi: imsi }
    end

    def sim_state
      res = @at.command("AT+CPIN?", expect: ["+CPIN:"])
      self.class.sim_state_from(find_line(res, "+CPIN:"))
    rescue AT::CommandError => e
      raise if %i[timeout disconnected].include?(e.kind)
      return { state: "not_inserted", detail: "SIM card not inserted" } if e.code == 10
      return { state: "unknown", detail: "SIM busy" } if e.code == 14

      { state: "error", detail: e.message }
    end

    def enter_pin(pin)
      raise Error, "SIM PIN must be 4-8 digits" unless pin.to_s.match?(/\A\d{4,8}\z/)

      @at.command(%(AT+CPIN="#{pin}"), timeout: 15)
    end

    def signal
      rssi, ber = params(@at.command("AT+CSQ", expect: ["+CSQ:"]), "+CSQ:").map { |v| self.class.number(v) }
      self.class.signal_from(rssi || 99, ber || 99)
    end

    def registration
      p = params(@at.command("AT+CREG?", expect: ["+CREG:"]), "+CREG:")
      self.class.registration_from(self.class.number(p[1] || p[0]))
    end

    def operator
      p = params(@at.command("AT+COPS?", expect: ["+COPS:"], timeout: 20), "+COPS:")
      p[2].to_s.empty? ? nil : p[2]
    end

    def battery
      p = params(@at.command("AT+CBC", expect: ["+CBC:"]), "+CBC:").map { |v| self.class.number(v) }
      { percent: p[1], voltage: p[2] }
    end

    def storage
      p = params(@at.command("AT+CPMS?", expect: ["+CPMS:"]), "+CPMS:")
      { used: self.class.number(p[1]), total: self.class.number(p[2]) }
    end

    # Submits one PDU and returns the TP-Message-Reference assigned by the modem.
    def send_pdu(part, timeout)
      res = @at.command("AT+CMGS=#{part.tpdu_length}", payload: part.pdu, expect: ["+CMGS:"], timeout: timeout)
      mr = self.class.number(find_line(res, "+CMGS:"))
      raise AT::CommandError.new(:error, res.command, "Invalid +CMGS reference in response") unless mr.is_a?(Integer)

      mr
    end

    # [{ index:, stat:, length:, pdu: }]
    def list_messages
      res = @at.command("AT+CMGL=4", expect: ["+CMGL:"], timeout: 30)
      out = []
      i = 0
      while i < res.lines.size
        line = res.lines[i]
        if line.start_with?("+CMGL:")
          p = self.class.split_params(self.class.after(line, "+CMGL:"))
          pdu = res.lines[i + 1]
          if pdu && !pdu.start_with?("+")
            out << { index: self.class.number(p[0]), stat: self.class.number(p[1]), length: self.class.number(p.last),
                     pdu: pdu }
            i += 1
          end
        end
        i += 1
      end
      out
    end

    def read_message(index)
      res = @at.command("AT+CMGR=#{index}", expect: ["+CMGR:"], timeout: 15)
      head = res.lines.index { |l| l.start_with?("+CMGR:") }
      return nil if head.nil? || res.lines[head + 1].nil?

      p = self.class.split_params(self.class.after(res.lines[head], "+CMGR:"))
      { index: index, stat: self.class.number(p[0]), length: self.class.number(p.last), pdu: res.lines[head + 1] }
    end

    def delete_message(index)
      @at.command("AT+CMGD=#{index}", timeout: 15)
    end

    # Dials a voice call. Returns the final result code (OK, BUSY, NO CARRIER...).
    def dial(number)
      raise Error, "Invalid dial string" unless number.to_s.match?(/\A\+?[0-9*#]{1,32}\z/)

      @at.command("ATD#{number};", final_codes: CALL_END_CODES.keys, timeout: 30, priority: CALL_PRIORITY).final
    end

    def hangup
      @at.command("ATH", timeout: 20, priority: CALL_PRIORITY)
    end

    def answer
      @at.command("ATA", final_codes: ["NO CARRIER"], timeout: 20, priority: CALL_PRIORITY).final
    end

    def send_dtmf(digits)
      raise Error, "Invalid DTMF digits" unless digits.to_s.match?(/\A[0-9*#A-D]{1,20}\z/i)

      @at.command(%(AT+VTS="#{digits.upcase.chars.join(',')}"), timeout: 5 + digits.size, priority: CALL_PRIORITY)
    end

    # Sends a USSD code (*123#) or a reply to a USSD menu. The network answers later with +CUSD.
    def send_ussd(text)
      raise Error, "Invalid USSD string" unless text.to_s.match?(USSD_TEXT)

      @at.command(%(AT+CUSD=1,"#{text}",15), timeout: 20, priority: CALL_PRIORITY - 1)
    end

    def cancel_ussd
      @at.command("AT+CUSD=2", priority: CALL_PRIORITY - 1)
    end

    def list_calls
      res = @at.command("AT+CLCC", expect: ["+CLCC:"], priority: CALL_PRIORITY - 1)
      res.lines.select { |l| l.start_with?("+CLCC:") }.filter_map { |l| self.class.parse_clcc(l) }
    end

    # Full functionality reset; the modem reboots and re-announces itself with RDY / SMS Ready.
    def restart
      @at.command("AT+CFUN=1,1", timeout: 15)
    end

    def raw(command, timeout = 10)
      # Treat "+XXX:" lines of the command itself as response (AT+CPIN? -> +CPIN:), not as URCs.
      name = /\AAT([+*#][A-Z]+)/i.match(command)&.[](1)&.upcase
      @at.command(command, timeout: timeout, expect: name ? ["#{name}:"] : [])
    end

    private

    def find_line(res, prefix)
      line = res.lines.find { |l| l.start_with?(prefix) }
      raise AT::CommandError.new(:error, res.command, "Missing #{prefix} in response") if line.nil?

      self.class.after(line, prefix)
    end

    def params(res, prefix) = self.class.split_params(find_line(res, prefix))

    def optional(command)
      @at.command(command)
    rescue AT::CommandError => e
      raise if %i[timeout disconnected].include?(e.kind)

      @logger.debug("[sim800c] Optional modem setting #{command} not supported: #{e.message}")
    end

    def on_urc(urc)
      line = urc.line
      data = urc.data
      klass = self.class

      if line.start_with?("+CMTI:", "+CDSI:")
        storage, index = klass.split_params(klass.after(line, line[0, 6]))
        index = klass.number(index)
        return emit(:event, { type: :other, line: line }) unless index.is_a?(Integer)

        type = line.start_with?("+CMTI:") ? :sms_stored : :status_report_stored
        return emit(:event, { type: type, storage: storage.to_s, index: index })
      end
      if line.start_with?("+CMT:") && data
        p = klass.split_params(klass.after(line, "+CMT:"))
        return emit(:event, { type: :sms_direct, pdu: data, length: klass.number(p.last) })
      end
      if line.start_with?("+CDS:") && data
        return emit(:event, { type: :status_report, pdu: data, length: klass.number(klass.after(line, "+CDS:")) })
      end
      return emit(:event, { type: :ring }) if line == "RING" || line.start_with?("+CRING:")
      if line.start_with?("+CLIP:")
        number = klass.split_params(klass.after(line, "+CLIP:"))[0]
        return emit(:event, { type: :clip, number: number.to_s.empty? ? nil : number })
      end
      if line.start_with?("+CCWA:")
        number = klass.split_params(klass.after(line, "+CCWA:"))[0]
        return emit(:event, { type: :call_waiting, number: number.to_s.empty? ? nil : number })
      end
      if line.start_with?("+CLCC:")
        call = klass.parse_clcc(line)
        return call ? emit(:event, { type: :clcc, call: call }) : nil
      end
      return emit(:event, { type: :call_ended, code: CALL_END_CODES[line] }) if CALL_END_CODES.key?(line)
      return emit(:event, { type: :mo_ring }) if line == "MO RING"
      return emit(:event, { type: :mo_connected }) if line == "MO CONNECTED"
      return emit(:event, { type: :ussd, **klass.parse_cusd(line) }) if line.start_with?("+CUSD:")
      if ["RDY", "Call Ready", "SMS Ready"].include?(line) || line.start_with?("+CFUN:")
        return emit(:event, { type: :boot, line: line })
      end
      return emit(:event, { type: :sim, **klass.sim_state_from(klass.after(line, "+CPIN:")) }) if line.start_with?("+CPIN:")
      if line.start_with?("UNDER-VOLTAGE", "OVER-VOLTAGE") || line == "NORMAL POWER DOWN"
        return emit(:event, { type: :power, line: line, fatal: line.include?("POWER DOWN") })
      end

      emit(:event, { type: :other, line: line })
    end
  end
end
