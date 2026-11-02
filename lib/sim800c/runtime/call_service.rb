# frozen_string_literal: true

module Sim800c
  class Runtime
    # Tracks the (single) current voice call and keeps the call history.
    class CallService
      END_GRACE = 0.6

      END_REASON_TEXT = {
        no_carrier: "Call ended by the network or remote party",
        busy: "Line busy",
        no_answer: "No answer",
        no_dialtone: "No dial tone",
        local_hangup: "Hung up from dashboard/API",
        remote_hangup: "Remote party hung up",
        rejected: "Rejected",
        ring_timeout: "No answer (ring timeout)",
        modem_disconnected: "Modem disconnected",
        error: "Call failed"
      }.freeze

      FINAL_CODES = { "BUSY" => :busy, "NO ANSWER" => :no_answer, "NO DIALTONE" => :no_dialtone }.freeze

      ActiveCall = Struct.new(:id, :direction, :phone, :status, :started_at, :answered_at, :alerted, :local_hangup,
                              :rejected, keyword_init: true)
      private_constant :ActiveCall

      def initialize(reactor:, bus:, manager:, config:, events:, logger:)
        @reactor = reactor
        @bus = bus
        @manager = manager
        @config = config
        @events = events
        @logger = logger
        @current = nil
        @watch_timer = nil
        @pending_end = nil
        @watching = false
        @waiting_logged = Set.new
      end

      def start
        now = Time.current
        Call.where(status: Call::ACTIVE_STATUSES).find_each do |call|
          answered = !call.answered_at.nil?
          call.update_columns(status: answered ? "completed" : "failed", end_reason: "Interrupted by application restart",
                              ended_at: now, duration: answered ? (now - call.answered_at).to_i : 0)
        end
        @manager.on(:event) { |e| on_modem_event(e) }
        @manager.on(:status) { |s| finalize(:modem_disconnected) if s[:connection] != "ready" && @current }
      end

      def stop
        stop_watch
        @pending_end&.cancel
      end

      # The call in progress, as the API returns it, or nil.
      def active
        @current && Call.find_by(id: @current.id)&.as_api
      end

      # -------------------------------------------------------------------------------------------
      # Commands (inside reactor tasks)
      # -------------------------------------------------------------------------------------------

      # Starts an outgoing call. Returns once the modem has accepted the dial command.
      def dial(number, actor)
        phone = Phone.normalize_dial_string(number)
        if Phone.ussd_code?(phone)
          raise AppError.bad_request("#{phone} is a USSD code, not a phone number: send it with POST /api/v1/ussd")
        end
        raise AppError.conflict("Another call is already in progress") if @current

        reason = @manager.unavailable_reason
        raise AppError.modem_unavailable(reason) if reason

        started_at = Time.current
        record = Call.create!(direction: "outbound", phone: phone, status: "dialing", source: actor[:source],
                              user_id: actor[:user_id], api_key_id: actor[:api_key_id], started_at: started_at)
        call = ActiveCall.new(id: record.id, direction: "outbound", phone: phone, status: "dialing",
                              started_at: started_at, answered_at: nil, alerted: false, local_hangup: false,
                              rejected: false)
        @current = call
        emit_update(call.id)
        start_watch
        @logger.info("[sim800c] Dialing #{phone} (call ##{call.id})")

        begin
          final = @manager.modem.dial(phone)
          finalize(FINAL_CODES.fetch(final, :no_carrier)) if final != "OK" && @current.equal?(call)
        rescue StandardError => e
          finalize(:error, e.message) if @current.equal?(call)
          @events.error("call", "Call to #{phone} failed: #{e.message}")
          raise AppError.new(502, "call_failed", "Call failed: #{e.message}")
        end
        get(call.id)
      end

      def hangup
        call = @current
        raise AppError.conflict("There is no active call") unless call

        call.local_hangup = true
        inbound_ringing = call.direction == "inbound" && call.answered_at.nil?
        call.rejected = true if inbound_ringing
        begin
          @manager.modem.hangup
        rescue StandardError => e
          @logger.warn("[sim800c] ATH failed: #{e.message}")
        end
        finalize(inbound_ringing ? :rejected : :local_hangup) if @current.equal?(call)
        get(call.id)
      end

      def answer
        call = @current
        unless call && call.direction == "inbound" && call.answered_at.nil?
          raise AppError.conflict("There is no incoming call to answer")
        end

        final = begin
          @manager.modem.answer
        rescue StandardError => e
          raise AppError.new(502, "call_failed", "Could not answer: #{e.message}")
        end
        raise AppError.conflict("The caller hung up") unless @current.equal?(call)

        final == "OK" ? mark_active(call) : finalize(:no_carrier)
        get(call.id)
      end

      def reject
        call = @current
        unless call && call.direction == "inbound" && call.answered_at.nil?
          raise AppError.conflict("There is no incoming call to reject")
        end

        hangup
      end

      def send_dtmf(digits)
        raise AppError.conflict("DTMF tones can only be sent during an active call") unless @current&.status == "active"

        @manager.modem.send_dtmf(digits)
        nil
      end

      private

      # -------------------------------------------------------------------------------------------
      # Modem events
      # -------------------------------------------------------------------------------------------

      def on_modem_event(event)
        call = @current
        case event[:type]
        when :ring then on_incoming(nil)
        when :clip then on_incoming(event[:number])
        when :clcc then on_clcc(event[:call])
        when :call_waiting then log_waiting_call(event[:number])
        when :mo_ring then mark_alerting(call) if call&.direction == "outbound"
        when :mo_connected then mark_active(call) if call&.direction == "outbound"
        when :call_ended
          finalize(event[:code] == :no_carrier && call.answered_at ? :remote_hangup : event[:code]) if call
        end
      end

      def on_incoming(number)
        call = @current
        if call
          if call.direction == "inbound" && number && !call.phone
            call.phone = number
            Call.where(id: call.id).update_all(phone: number)
            emit_update(call.id, "call.incoming")
          end
          return
        end
        started_at = Time.current
        record = Call.create!(direction: "inbound", phone: number, status: "ringing", source: "modem",
                              started_at: started_at)
        @current = ActiveCall.new(id: record.id, direction: "inbound", phone: number, status: "ringing",
                                  started_at: started_at, answered_at: nil, alerted: true, local_hangup: false,
                                  rejected: false)
        @logger.info("[sim800c] Incoming call ##{record.id} from #{number || 'unknown number'}")
        emit_update(record.id, "call.incoming")
        start_watch
      end

      def on_clcc(entry)
        call = @current
        case entry[:state]
        when "incoming" then on_incoming(entry[:number])
        when "waiting" then log_waiting_call(entry[:number])
        when "alerting"
          mark_alerting(call) if call&.direction == "outbound" && entry[:direction] == "outbound"
        when "active"
          mark_active(call) if call && call.direction == entry[:direction]
        when "disconnected"
          return if call.nil? || call.direction != entry[:direction]

          if call.direction == "outbound" && call.answered_at.nil? && !call.local_hangup
            # +CLCC reports the disconnect just before the BUSY / NO ANSWER result code; give the
            # more specific code a moment to arrive before falling back to a generic reason.
            @pending_end&.cancel
            @pending_end = @reactor.after(END_GRACE) { finalize(:no_carrier) if @current.equal?(call) }
          elsif call.answered_at
            finalize(call.local_hangup ? :local_hangup : :remote_hangup)
          else
            finalize(:no_carrier)
          end
        end
      end

      def log_waiting_call(number)
        key = number || "unknown"
        return if @current.nil? || @waiting_logged.include?(key)

        @waiting_logged << key
        now = Time.current
        record = Call.create!(direction: "inbound", phone: number, status: "missed",
                              end_reason: "Call waiting — line was busy", source: "modem", started_at: now,
                              ended_at: now, duration: 0)
        @events.info("call", "Missed call from #{number || 'unknown number'} (line busy)")
        emit_update(record.id, "call.ended")
      end

      def mark_alerting(call)
        call.alerted = true
        set_status(call, "ringing") if call.status == "dialing"
      end

      def mark_active(call)
        return unless call.answered_at.nil?

        call.answered_at = Time.current
        call.status = "active"
        Call.where(id: call.id).update_all(status: "active", answered_at: call.answered_at)
        emit_update(call.id)
      end

      def set_status(call, status)
        call.status = status
        Call.where(id: call.id).update_all(status: status)
        emit_update(call.id)
      end

      def finalize(reason, error = nil)
        call = @current
        return unless call

        @current = nil
        @pending_end&.cancel
        @waiting_logged.clear
        stop_watch
        # The disconnect URC caused by our own ATH should be attributed to us.
        if call.local_hangup && %i[no_carrier remote_hangup].include?(reason)
          reason = call.rejected ? :rejected : :local_hangup
        end

        status = if call.answered_at then "completed"
                 elsif call.direction == "inbound" then call.rejected ? "rejected" : "missed"
                 elsif reason == :busy then "busy"
                 elsif %i[no_answer ring_timeout].include?(reason) then "no_answer"
                 elsif call.local_hangup then "cancelled"
                 elsif reason == :no_carrier then call.alerted ? "no_answer" : "failed"
                 else "failed"
                 end

        ended_at = Time.current
        duration = call.answered_at ? (ended_at - call.answered_at).round : 0
        end_reason = if status == "missed"
                       reason == :modem_disconnected ? END_REASON_TEXT[:modem_disconnected] : "Caller hung up before answer"
                     else
                       END_REASON_TEXT[reason]
                     end
        Call.where(id: call.id).update_all(status: status, end_reason: end_reason, error: error, ended_at: ended_at,
                                           duration: duration)
        @logger.info("[sim800c] Call ##{call.id} ended: #{status} (#{reason}, #{duration}s)")
        @events.info("call", "Missed call from #{call.phone || 'unknown number'}") if status == "missed"
        emit_update(call.id, "call.ended")
      end

      # -------------------------------------------------------------------------------------------
      # Supervision: ring timeout and AT+CLCC polling as a fallback for missed URCs
      # -------------------------------------------------------------------------------------------

      def start_watch
        stop_watch
        @watch_timer = @reactor.every(@config.poll_interval) { watch }
      end

      def stop_watch
        @watch_timer&.cancel
        @watch_timer = nil
      end

      def watch
        call = @current
        return if call.nil? || @watching

        @watching = true
        begin
          if call.direction == "outbound" && call.answered_at.nil? && Time.current - call.started_at > @config.ring_timeout
            call.local_hangup = true
            begin
              @manager.modem.hangup
            rescue StandardError
              nil
            end
            finalize(:ring_timeout) if @current.equal?(call)
            return
          end
          calls = @manager.modem.list_calls
          return unless @current.equal?(call)

          match = calls.find { |c| c[:direction] == call.direction && !%w[waiting disconnected].include?(c[:state]) }
          if match
            on_clcc(match)
          elsif Time.current - call.started_at > 3
            finalize(call.answered_at ? :remote_hangup : :no_carrier)
          end
        rescue StandardError => e
          @logger.debug("[sim800c] Call status poll failed: #{e.message}")
        ensure
          @watching = false
        end
      end

      def get(id) = Call.find(id).as_api

      def emit_update(id, extra = nil)
        record = Call.find_by(id: id)&.as_api
        return unless record

        @bus.emit("call.updated", record)
        @bus.emit(extra, record) if extra
      end
    end
  end
end
