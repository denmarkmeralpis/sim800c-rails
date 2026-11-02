# frozen_string_literal: true

require "set"

module Sim800c
  module AT
    # final: OK, or one of the command's final_codes.
    Response = Data.define(:command, :lines, :final, :duration_ms)

    # Unsolicited result code. `data` carries the second line of two-line URCs (+CMT, +CDS).
    Urc = Data.define(:line, :data) do
      def initialize(line:, data: nil) = super
    end

    # Serialises AT commands over a transport: one command in flight at a time, per-command
    # timeouts, '>' prompt handling for SMS submission, and URC demultiplexing.
    #
    # Reactor-thread only. Emits :urc (Urc), :timeout (command) and :success.
    class Client
      include Emitter

      URC_EXACT = Set[
        "RING", "NO CARRIER", "BUSY", "NO ANSWER", "NO DIALTONE", "MO RING", "MO CONNECTED",
        "RDY", "Call Ready", "SMS Ready", "NORMAL POWER DOWN"
      ].freeze

      URC_PREFIXES = [
        "+CMTI:", "+CDSI:", "+CMT:", "+CDS:", "+CBM:", "+CLIP:", "+CLCC:", "+CRING:", "+CCWA:", "+CUSD:",
        "+CPIN:", "+CFUN:", "+CREG:", "+CGREG:", "+CSQN:", "+CTZV:", "*PSUTTZ:", "DST:", "+CIEV:",
        "UNDER-VOLTAGE", "OVER-VOLTAGE"
      ].freeze

      # URCs whose payload (a PDU in PDU mode) follows on the next line.
      TWO_LINE_URC = /\A\+(CMT|CDS|CBM):/
      MAX_BUFFER = 64 * 1024
      MAX_TRAFFIC = 300
      # After a timeout, give late output from the modem a moment to drain before the next command.
      TIMEOUT_SETTLE = 0.3

      Pending = Struct.new(:command, :timeout, :expect, :final_codes, :payload, :priority, :promise, :lines,
                           :started_at, :awaiting_prompt, :timer, keyword_init: true)
      private_constant :Pending

      def self.urc?(line)
        URC_EXACT.include?(line) || URC_PREFIXES.any? { |p| line.start_with?(p) }
      end

      # Last MAX_TRAFFIC lines: { t: epoch ms, dir: "tx" | "rx" | "urc", line: }
      attr_reader :traffic

      def initialize(transport, reactor:, logger: Sim800c.logger, default_timeout: 10, log_traffic: false)
        @transport = transport
        @reactor = reactor
        @logger = logger
        @default_timeout = default_timeout
        @log_traffic = log_traffic
        @queue = []
        @current = nil
        @buffer = +""
        @pending_urc = nil
        @traffic = []
        transport.on(:data) { |chunk| on_data(chunk) }
      end

      def pending_count = @queue.size + (@current ? 1 : 0)

      # Queues a command; returns a Promise of a Response (or a rejected CommandError).
      #   expect:      prefixes of information lines that belong to this command (not URCs)
      #   final_codes: additional final result codes (e.g. BUSY / NO CARRIER for ATD)
      #   payload:     written after the '>' prompt and terminated with Ctrl-Z (AT+CMGS)
      #   priority:    higher priority commands jump the queue (call control vs polling)
      def execute(command, timeout: nil, expect: nil, final_codes: nil, payload: nil, priority: 0)
        if command.match?(/[\r\n\x1a\e]/)
          return Promise.rejected(CommandError.new(:error, command, "Invalid characters in AT command"))
        end

        pending = Pending.new(command: command, timeout: timeout || @default_timeout, expect: expect || [],
                              final_codes: final_codes || [], payload: payload, priority: priority,
                              promise: Promise.new, lines: [], awaiting_prompt: false)
        idx = @queue.index { |q| q.priority < priority }
        idx ? @queue.insert(idx, pending) : @queue.push(pending)
        pump
        pending.promise
      end

      # Like #execute, but waits (inside a reactor task) and returns the Response.
      def command(command, **options)
        @reactor.await(execute(command, **options))
      end

      # Rejects the in-flight command and everything queued (used on disconnect).
      def fail_all(reason)
        all = [@current, *@queue].compact
        @current&.timer&.cancel
        @current = nil
        @queue = []
        @buffer = +""
        @pending_urc = nil
        all.each { |p| p.promise.reject(CommandError.new(:disconnected, p.command, reason)) }
      end

      private

      def pump
        return if @current || @queue.empty?

        unless @transport.open?
          fail_all("Modem is not connected")
          return
        end
        pending = @queue.shift
        @current = pending
        pending.started_at = Reactor.now
        pending.awaiting_prompt = !pending.payload.nil?
        pending.timer = @reactor.after(pending.timeout) { on_timeout(pending) }
        record(:tx, pending.command)
        write("#{pending.command}\r", pending)
      end

      def write(data, pending)
        @transport.write(data).on_settle do |w|
          if w.rejected?
            finish(pending, CommandError.new(:disconnected, pending.command, "Write failed: #{w.reason.message}"))
          end
        end
      end

      def on_timeout(pending)
        return unless @current.equal?(pending)

        # Abort a pending SMS body so the modem returns to command mode.
        @transport.write("\e") if pending.awaiting_prompt || pending.payload
        ms = ((Reactor.now - pending.started_at) * 1000).round
        emit(:timeout, pending.command)
        finish(pending, CommandError.new(:timeout, pending.command, "No response to #{pending.command} after #{ms} ms"))
      end

      def finish(pending, result)
        return unless @current.equal?(pending)

        pending.timer&.cancel
        @current = nil
        if result.is_a?(CommandError)
          pending.promise.reject(result)
        else
          emit(:success)
          pending.promise.resolve(result)
        end
        if result.is_a?(CommandError) && result.kind == :timeout
          @reactor.after(TIMEOUT_SETTLE) { pump }
        else
          @reactor.post { pump }
        end
      end

      def complete(pending, final)
        duration = ((Reactor.now - pending.started_at) * 1000).round
        finish(pending, Response.new(command: pending.command, lines: pending.lines, final: final, duration_ms: duration))
      end

      def on_data(chunk)
        # Like Node's latin1 decoding: every byte maps to one character, so nothing is lost.
        @buffer << chunk.dup.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
        if @buffer.size > MAX_BUFFER
          @logger.warn("[sim800c] Modem receive buffer overflow — discarding (check baud rate)")
          @buffer = +""
        end

        while (idx = line_end)
          line = @buffer.slice!(0, idx + 1)[0, idx].strip
          on_line(line) unless line.empty?
        end

        cur = @current
        return unless cur&.awaiting_prompt && @buffer.lstrip.start_with?(">")

        @buffer = +""
        cur.awaiting_prompt = false
        record(:rx, ">")
        record(:tx, "#{cur.payload[0, 64]}#{cur.payload.size > 64 ? '…' : ''} <Ctrl-Z>")
        write("#{cur.payload}\x1a", cur)
      end

      # Index of the line break ending the next complete line, or nil. USSD menus put line breaks
      # inside the quoted text (+CUSD: 1,"Menu\n1 Balance\n2 Promos",15), so wait for the closing quote.
      def line_end
        idx = @buffer.index(/[\r\n]/)
        return idx if idx.nil? || !@buffer[0, idx].lstrip.start_with?("+CUSD:")

        open = @buffer.index('"')
        return idx if open.nil? || open > idx

        close = @buffer.index('"', open + 1)
        return nil if close.nil?

        rel = @buffer[close..].index(/[\r\n]/)
        rel && close + rel
      end

      def on_line(line)
        if @pending_urc
          head = @pending_urc
          @pending_urc = nil
          if line.match?(/\A[0-9A-Fa-f]+\z/)
            record(:urc, line)
            emit(:urc, Urc.new(line: head, data: line))
            return
          end
          emit(:urc, Urc.new(line: head))
        end

        cur = @current
        if cur
          return if line.upcase == cur.command.upcase # command echo

          if line == "OK"
            record(:rx, line)
            return complete(cur, line)
          end
          if (err = AT.parse_error_line(line))
            record(:rx, line)
            return finish(cur, CommandError.new(err.kind, cur.command, err.message, err.code))
          end
          if cur.final_codes.include?(line)
            record(:rx, line)
            return complete(cur, line)
          end
          if cur.expect.any? { |prefix| line.start_with?(prefix) } || !self.class.urc?(line)
            record(:rx, line)
            cur.lines << line
            return
          end
        elsif !self.class.urc?(line)
          # Late reply to a timed-out command, stray echo or line noise.
          record(:rx, line)
          @logger.debug("[sim800c] Ignoring unsolicited modem output: #{line.inspect}")
          return
        end

        record(:urc, line)
        if line.match?(TWO_LINE_URC)
          @pending_urc = line
          return
        end
        emit(:urc, Urc.new(line: line))
      end

      def record(dir, line)
        @logger.debug("[sim800c] AT #{dir} #{line.inspect}") if @log_traffic
        @traffic << { t: (Time.now.to_f * 1000).to_i, dir: dir.to_s, line: line }
        @traffic.shift if @traffic.size > MAX_TRAFFIC
      end
    end
  end
end
