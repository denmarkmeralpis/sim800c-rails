# frozen_string_literal: true

module Sim800c
  module Transport
    # In-process SIM800C emulator. Speaks the subset of the AT command set the gateway uses
    # (PDU-mode SMS, voice calls, USSD, status queries) including URCs, so the real AT client, PDU
    # codec and services run unchanged without hardware. Lives on the reactor thread.
    #
    # Magic numbers for testing outgoing traffic:
    #   SMS to a number ending in 0000 -> +CMS ERROR: 1 (unassigned number, permanent)
    #   SMS to a number ending in 4444 -> sent, then delivery report "validity period expired"
    #   Call to a number ending in 000 -> BUSY
    #   Call to a number ending in 888 -> rejected by the remote party (NO CARRIER)
    #   Call to a number ending in 999 -> rings until NO ANSWER
    #   Any other call is answered after a few seconds.
    #   USSD *123# -> balance; *143# -> a menu (1 balance, 2 promos); a code ending in 999# -> no
    #   reply; any other code -> +CUSD: 4 (not supported).
    class Simulator < Base
      CAPACITY = 30
      OPERATOR = "SIMULATED GSM"
      SMSC = "+639170000130"
      BALANCE = '+CUSD: 0,"Your balance is P123.45, valid until 31-12-2026.",15'

      SimCall = Struct.new(:dir, :stat, :number)
      private_constant :SimCall

      # Messages accepted for delivery: [{ to:, text:, mr: }]
      attr_reader :sent

      def initialize(reactor, time_scale: 1.0, sms_failure_rate: 0.0)
        super(reactor)
        @scale = time_scale.to_f
        @failure_rate = sms_failure_rate.to_f
        @sent = []
        @opened = false
        @unplugged_until = 0
        @frozen_until = 0
        @rx = +""
        @pdu_input = nil
        @timers = []
        @signal_timer = nil
        reset_settings
        @sim_inserted = true
        @registration = 1
        @rssi = 21
        @storage = {}
        @mr = 0
        @concat_ref = 0
        @call = nil
        @ussd_menu = false
      end

      def description = "SIM800C simulator"
      def open? = @opened

      def open
        if Reactor.now < @unplugged_until
          return Promise.rejected(Error.new("cannot open simulator: device not found (unplugged)"))
        end

        @opened = true
        @rx = +""
        @pdu_input = nil
        @signal_timer&.cancel
        @signal_timer = reactor.every(5 * @scale) do
          @rssi = (@rssi + ((rand * 2) - 1).round).clamp(6, 29)
        end
        Promise.resolved
      end

      def close
        return Promise.resolved unless @opened

        shutdown
        reactor.post { emit(:close, nil) }
        Promise.resolved
      end

      def write(data)
        return Promise.rejected(Error.new("Port is not open")) unless @opened
        return Promise.resolved if Reactor.now < @frozen_until # simulated hang: input is lost

        data.to_s.b.each_char { |ch| on_char(ch) }
        Promise.resolved
      end

      # -------------------------------------------------------------------------------------------
      # Control API (simulator endpoints and tests). Reactor thread only.
      # -------------------------------------------------------------------------------------------

      def snapshot
        {
          connected: @opened,
          simInserted: @sim_inserted,
          registration: @registration,
          rssi: @rssi,
          storageUsed: @storage.size,
          storageCapacity: CAPACITY,
          frozen: Reactor.now < @frozen_until,
          call: @call && { direction: @call.dir == 1 ? "inbound" : "outbound", state: @call.stat, number: @call.number }
        }
      end

      # Delivers an SMS from the "network": stores it on the SIM and raises +CMTI.
      def inject_sms(from, text)
        raise Error, "Simulated modem is offline or has no SIM" unless @opened && @sim_inserted

        parts = PDU.encode_deliver(from: from, text: text, smsc: SMSC, reference: @concat_ref & 0xff)
        @concat_ref += 1
        indices = []
        parts.each_with_index do |part, i|
          index = free_index
          next if index.nil?

          @storage[index] = { stat: 0, pdu: part.pdu, length: part.tpdu_length }
          indices << index
          urc(%(+CMTI: "SM",#{index}), 100 + (i * 150)) if @cnmi_mt == 1
        end
        indices
      end

      # Simulates an incoming voice call (RING / +CLIP every 3 s until answered or abandoned).
      def inject_call(from)
        raise Error, "Simulated modem cannot receive calls" unless @opened && @sim_inserted && registered?

        toa = from.start_with?("+") ? 145 : 129
        if @call
          urc(%(+CLCC: 2,1,5,0,0,"#{from}",#{toa},"")) if @clcc_urc
          after(6000) { urc(%(+CLCC: 2,1,6,0,0,"#{from}",#{toa},"")) if @clcc_urc }
          return
        end
        call = SimCall.new(1, 4, from)
        @call = call
        emit_clcc
        ring = nil
        ring = lambda do
          next unless @call.equal?(call) && call.stat == 4

          urc("RING")
          urc(%(+CLIP: "#{from}",#{toa},"",0,"",0)) if @clip
          after(3000, &ring)
        end
        ring.call
        after(25_000) { end_call("NO CARRIER") if @call.equal?(call) && call.stat == 4 }
        nil
      end

      def remote_hangup
        return false unless @call

        end_call("NO CARRIER")
        true
      end

      def signal=(rssi)
        @rssi = rssi
      end

      def registration=(stat)
        @registration = stat
        end_call("NO CARRIER") if !registered? && @call
      end

      def sim_inserted=(inserted)
        return if inserted == @sim_inserted

        @sim_inserted = inserted
        if inserted
          urc("+CPIN: READY", 300)
          urc("Call Ready", 900)
          urc("SMS Ready", 1200)
        else
          end_call("NO CARRIER") if @call
          urc("+CPIN: NOT INSERTED")
        end
      end

      # Simulates the USB cable being pulled; the port cannot be reopened for `seconds`.
      def unplug(seconds)
        return unless @opened

        @unplugged_until = Reactor.now + seconds
        shutdown
        reactor.post { emit(:close, Error.new("Device disconnected (simulated unplug)")) }
      end

      # Simulates a hung modem that ignores input for `seconds`.
      def freeze(seconds)
        @frozen_until = Reactor.now + seconds
      end

      # Simulates a spontaneous modem reboot (brown-out, watchdog...).
      def reboot
        reset_settings
        @call = nil
        @ussd_menu = false
        urc("RDY", 800)
        urc("+CFUN: 1", 900)
        urc("+CPIN: READY", 1000) if @sim_inserted
        urc("Call Ready", 2000)
        urc("SMS Ready", 2100)
      end

      private

      def registered? = @sim_inserted && [1, 5].include?(@registration)

      def shutdown
        @opened = false
        @call = nil
        @ussd_menu = false
        @pdu_input = nil
        @rx = +""
        @timers.each(&:cancel)
        @timers.clear
        @signal_timer&.cancel
      end

      def reset_settings
        @echo = true
        @cmee = 0
        @cmgf = 1
        @cnmi_mt = 0
        @cnmi_ds = 0
        @clip = false
        @clcc_urc = false
        @moring = false
      end

      # Runs the block after `ms` simulated milliseconds, unless the port was closed meanwhile. Like
      # setTimeout, delays under 1 ms count as 1 ms, so output keeps the order a real modem produces.
      def after(ms, &block)
        timer = nil
        timer = reactor.after([ms * @scale, 1].max / 1000.0) do
          @timers.delete(timer)
          block.call if @opened
        end
        @timers << timer
      end

      def out(raw, delay_ms = 15)
        bytes = raw.encode(Encoding::ISO_8859_1, invalid: :replace, undef: :replace).b
        after(delay_ms) { emit(:data, bytes) }
      end

      def respond(lines, final = "OK", delay_ms = 15)
        out(lines.map { |l| "\r\n#{l}\r\n" }.join + "\r\n#{final}\r\n", delay_ms)
      end

      def cme(code, delay_ms = 15)
        out(@cmee.positive? ? "\r\n+CME ERROR: #{code}\r\n" : "\r\nERROR\r\n", delay_ms)
      end

      def cms(code, delay_ms = 15)
        out(@cmee.positive? ? "\r\n+CMS ERROR: #{code}\r\n" : "\r\nERROR\r\n", delay_ms)
      end

      def urc(line, delay_ms = 20)
        out("\r\n#{line}\r\n", delay_ms)
      end

      def free_index
        (1..CAPACITY).find { |i| !@storage.key?(i) }
      end

      def on_char(ch)
        if @pdu_input
          case ch
          when "\x1a"
            length = @pdu_input
            pdu = @rx.strip
            @pdu_input = nil
            @rx = +""
            handle_submit(pdu, length)
          when "\e"
            @pdu_input = nil
            @rx = +""
          else
            @rx << ch
          end
          return
        end
        case ch
        when "\r"
          line = @rx.strip
          @rx = +""
          handle_command(line) unless line.empty?
        when "\e"
          @rx = +""
        when "\n"
          nil
        else
          @rx << ch
        end
      end

      def handle_command(line)
        out("#{line}\r", 1) if @echo
        return respond([], "ERROR") unless line.match?(/\AAT/i)

        body = line[2..]
        b = body.upcase
        sim_ready = @sim_inserted

        case b
        when "" then respond([])
        when "E0", "E1"
          @echo = b == "E1"
          respond([])
        when /\A\+CMEE=(\d)\z/
          @cmee = Regexp.last_match(1).to_i
          respond([])
        when "I" then respond(["SIM800 R14.18"])
        when "+CGMI" then respond(["SIMCOM_Ltd"])
        when "+CGMM" then respond(["SIMCOM_SIM800C"])
        when "+CGMR" then respond(["Revision:1418B05SIM800C24"])
        when "+GSN" then respond(["869170031234567"])
        when "+CCID" then sim_ready ? respond(["8963012345678901234f"]) : cme(10)
        when "+CIMI" then sim_ready ? respond(["515021234567890"]) : cme(10)
        when "+CPIN?" then sim_ready ? respond(["+CPIN: READY"]) : cme(10)
        when /\A\+CPIN=/ then sim_ready ? cme(3) : cme(10)
        when /\A\+CMGF=(\d)\z/
          @cmgf = Regexp.last_match(1).to_i
          respond([])
        when /\A\+(CSCS|CRC|COLP|CREG)=/ then respond([])
        when /\A\+CPMS=/
          n = @storage.size
          sim_ready ? respond(["+CPMS: #{n},#{CAPACITY},#{n},#{CAPACITY},#{n},#{CAPACITY}"]) : cms(310)
        when "+CPMS?"
          n = @storage.size
          respond([%(+CPMS: "SM",#{n},#{CAPACITY},"SM",#{n},#{CAPACITY},"SM",#{n},#{CAPACITY})])
        when /\A\+CNMI=(\d),(\d),(\d),(\d),(\d)\z/
          @cnmi_mt = Regexp.last_match(2).to_i
          @cnmi_ds = Regexp.last_match(4).to_i
          respond([])
        when /\A\+CLIP=(\d)\z/
          @clip = Regexp.last_match(1) == "1"
          respond([])
        when /\A\+CLCC=(\d)\z/
          @clcc_urc = Regexp.last_match(1) == "1"
          respond([])
        when /\A\+MORING=(\d)\z/
          @moring = Regexp.last_match(1) == "1"
          respond([])
        when "+CSQ" then respond(["+CSQ: #{@sim_inserted ? @rssi : 99},0"])
        when "+CREG?" then respond(["+CREG: 0,#{@sim_inserted ? @registration : 0}"])
        when "+COPS?" then respond([registered? ? %(+COPS: 0,0,"#{OPERATOR}") : "+COPS: 0"])
        when "+CBC" then respond(["+CBC: 0,87,4120"])
        when "+CFUN?" then respond(["+CFUN: 1"])
        when /\A\+CMGL=(\d)\z/ then list_stored(Regexp.last_match(1).to_i)
        when /\A\+CMGR=(\d+)\z/ then read_stored(Regexp.last_match(1).to_i)
        when /\A\+CMGD=(\d+)(?:,(\d))?\z/
          if Regexp.last_match(2) == "4"
            @storage.clear
          else
            @storage.delete(Regexp.last_match(1).to_i)
          end
          respond([], "OK", 30)
        when /\A\+CMGS=(\d+)\z/
          return cms(302) unless @cmgf.zero?
          return cms(310) unless sim_ready

          @pdu_input = Regexp.last_match(1).to_i
          out("\r\n> ", 20)
        when /\AD([+0-9*#]+);\z/ then dial(Regexp.last_match(1))
        when "H", "H0"
          end_call(nil) if @call
          respond([])
        when "A" then answer
        when "+CLCC" then respond(@call ? [clcc_line(@call)] : [])
        when /\A\+VTS=/ then @call&.stat&.zero? ? respond([], "OK", 200) : cme(3)
        when "+CFUN=1,1"
          respond([])
          after(100) { reboot }
        else
          if (m = /\A\+CUSD=(\d)(?:,"([^"]*)"(?:,\d+)?)?\z/i.match(body))
            ussd(m[1].to_i, m[2])
          else
            respond([], "ERROR")
          end
        end
      end

      def list_stored(stat)
        return cms(302) unless @cmgf.zero?

        lines = []
        @storage.sort_by(&:first).each do |index, msg|
          next if stat != 4 && msg[:stat] != stat

          lines.push("+CMGL: #{index},#{msg[:stat]},,#{msg[:length]}", msg[:pdu])
          msg[:stat] = 1 if msg[:stat].zero?
        end
        respond(lines, "OK", 40)
      end

      def read_stored(index)
        msg = @storage[index]
        return respond([]) unless msg

        lines = ["+CMGR: #{msg[:stat]},,#{msg[:length]}", msg[:pdu]]
        msg[:stat] = 1 if msg[:stat].zero?
        respond(lines, "OK", 30)
      end

      def handle_submit(pdu, length)
        begin
          decoded = PDU.decode(pdu)
          smsc_length = [pdu[0, 2]].pack("H*").unpack1("C")
          raise PDU::Error, "bad pdu" unless decoded.type == :submit && (pdu.size / 2) - 1 - smsc_length == length
        rescue PDU::Error
          return cms(304, 100)
        end
        to = decoded.recipient

        return cms(331, 800) unless registered?
        return cms(1, 900) if to.end_with?("0000")
        return cms(42, 1200) if rand < @failure_rate

        @mr = (@mr + 1) % 256
        mr = @mr
        @sent << { to: to, text: decoded.text, mr: mr }
        respond(["+CMGS: #{mr}"], "OK", 1200)
        return unless decoded.status_report && @cnmi_ds == 1

        after(3000) do
          report = PDU.encode_status_report(reference: mr, recipient: to, status: to.end_with?("4444") ? 0x46 : 0x00,
                                            submitted_at: Time.now - 3, discharged_at: Time.now)
          out("\r\n+CDS: #{report.tpdu_length}\r\n#{report.pdu}\r\n", 0)
        end
      end

      def dial(number)
        return cme(30, 300) unless registered?
        return cme(3) if @call

        call = SimCall.new(0, 2, number)
        @call = call
        respond([], "OK", 200)
        after(250) { emit_clcc }
        active = -> { @call.equal?(call) }

        after(1500) do
          next unless active.call && call.stat == 2

          call.stat = 3
          emit_clcc
          urc("MO RING", 0) if @moring
        end

        if number.end_with?("000")
          after(3500) { end_call("BUSY") if active.call }
        elsif number.end_with?("888")
          after(5000) { end_call("NO CARRIER") if active.call }
        elsif number.end_with?("999")
          after(30_000) { end_call("NO ANSWER") if active.call }
        else
          after(4500) do
            next unless active.call && call.stat == 3

            call.stat = 0
            emit_clcc
            urc("MO CONNECTED", 0) if @moring
            after(120_000) { end_call("NO CARRIER") if active.call }
          end
        end
      end

      def ussd(mode, text)
        if mode == 2
          @ussd_menu = false
          return respond([])
        end
        return respond([]) if text.nil?
        return cme(30, 300) unless registered?

        respond([], "OK", 100)
        reply = ussd_reply(text)
        after(1500) { urc(reply, 0) } if reply
      end

      # A tiny operator: the network's +CUSD answer to a code or menu choice (nil: never answers).
      def ussd_reply(text)
        in_menu = @ussd_menu
        @ussd_menu = false
        if in_menu
          return BALANCE if text == "1"
          return '+CUSD: 0,"No promos available right now.",15' if text == "2"

          return '+CUSD: 0,"Invalid option.",15'
        end
        return BALANCE if text == "*123#"
        if text == "*143#"
          @ussd_menu = true
          return %(+CUSD: 1,"Services\n1 Balance\n2 Promos",15)
        end
        return nil if text.end_with?("999#")

        "+CUSD: 4"
      end

      def answer
        call = @call
        return respond([], "NO CARRIER", 100) unless call && call.dir == 1 && call.stat == 4

        call.stat = 0
        respond([], "OK", 300)
        after(320) { emit_clcc }
        after(90_000) { end_call("NO CARRIER") if @call.equal?(call) }
      end

      def end_call(urc_line)
        call = @call
        return unless call

        call.stat = 6
        emit_clcc(call)
        @call = nil
        urc(urc_line, 25) if urc_line
      end

      def clcc_line(call)
        %(+CLCC: 1,#{call.dir},#{call.stat},0,0,"#{call.number}",#{call.number.start_with?('+') ? 145 : 129},"")
      end

      def emit_clcc(call = @call)
        urc(clcc_line(call), 0) if call && @clcc_urc
      end
    end
  end
end
