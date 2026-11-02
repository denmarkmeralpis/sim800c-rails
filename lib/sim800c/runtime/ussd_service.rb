# frozen_string_literal: true

module Sim800c
  class Runtime
    # Runs USSD sessions (*123# balance checks, operator menus) and keeps their history. One session
    # at a time; the current one lives in memory and is written to the database on every change.
    class UssdService
      END_REASON_TEXT = {
        ended: "Session ended by the network",
        other_client: "Answered by another client",
        unsupported: "Code not supported by the network",
        timeout: "Network timed out"
      }.freeze

      ActiveSession = Struct.new(:id, :code, :status, :response, :error, :messages, :source, :started_at, :updated_at,
                                 keyword_init: true)
      private_constant :ActiveSession

      def initialize(reactor:, bus:, manager:, timeout:, events:, logger:)
        @reactor = reactor
        @bus = bus
        @manager = manager
        @timeout = timeout
        @events = events
        @logger = logger
        @session = nil
        @settle = nil
        @timer = nil
      end

      def start
        # The network forgets a session when the modem resets, so one cut short by a restart cannot be resumed.
        interrupted = UssdSession.where(status: UssdSession::OPEN_STATUSES)
                                 .update_all(status: "failed", error: "Interrupted by a restart", updated_at: Sim800c.now)
        if interrupted.positive?
          @events.warn("ussd", "Marked #{interrupted} USSD session(s) interrupted by a restart as failed")
        end
        @session = load(UssdSession.latest)

        @manager.on(:event) { |e| on_response(e[:state], e[:text]) if e[:type] == :ussd }
        @manager.on(:status) do |s|
          finish(@session, "failed", "Modem disconnected") if s[:connection] != "ready" && open?(@session)
        end
      end

      def stop
        @timer&.cancel
      end

      # The latest session, finished or not, as the API returns it.
      def current
        @session && as_api(@session)
      end

      # -------------------------------------------------------------------------------------------
      # Commands (inside reactor tasks)
      # -------------------------------------------------------------------------------------------

      # Sends a code such as *123# and returns once the network has answered.
      def send_code(input, actor)
        code = Phone.normalize_ussd_code(input)
        raise AppError.conflict("A USSD request is already waiting for the network") if @session&.status == "pending"

        reason = @manager.unavailable_reason
        raise AppError.modem_unavailable(reason) if reason

        # Like on a phone, dialing a new code closes a menu that is still open.
        cancel if open?(@session)
        @session = create(code, actor)
        @logger.info("[sim800c] Sending USSD #{code} (session ##{@session.id})")
        request(@session, code)
      end

      # Answers a menu (status "open"), e.g. with "1".
      def reply(text)
        session = @session
        raise AppError.conflict("There is no USSD menu waiting for a reply") unless session&.status == "open"

        reason = @manager.unavailable_reason
        raise AppError.modem_unavailable(reason) if reason

        session.status = "pending"
        request(session, text)
      end

      def cancel
        session = @session
        raise AppError.conflict("There is no USSD session to cancel") unless open?(session)

        # Finish first: some firmware answers AT+CUSD=2 with "+CUSD: 2", which must not count as the network ending it.
        finish(session, "cancelled", nil)
        begin
          @manager.modem.cancel_ussd
        rescue StandardError => e
          @logger.debug("[sim800c] AT+CUSD=2 failed: #{e.message}")
        end
        as_api(session)
      end

      private

      def open?(session) = !session.nil? && UssdSession::OPEN_STATUSES.include?(session.status)

      def request(session, text)
        push(session, "outbound", text)
        save(session)
        answered = Promise.new
        @settle = answered
        @timer&.cancel
        @timer = @reactor.after(@timeout) do
          if finish(session, "failed", "No reply from the network")
            begin
              @manager.modem.cancel_ussd
            rescue StandardError
              nil
            end
          end
        end
        begin
          @manager.modem.send_ussd(text)
        rescue StandardError => e
          return as_api(session) unless finish(session, "failed", e.message) # cancelled meanwhile

          raise AppError.new(502, "ussd_failed", "USSD request failed: #{e.message}")
        end
        @reactor.await(answered)
        as_api(session)
      end

      def on_response(state, text)
        session = @session
        unless open?(session)
          # Pushed by the network (operator notification), or a late reply to a finished session.
          return unless text

          session = @session = create(nil, { source: "modem" })
        end
        if text
          session.response = text
          push(session, "inbound", text)
        end
        if state == :reply
          session.status = "open"
          resolve_pending
          save(session)
        elsif state == :done || (state == :ended && text)
          finish(session, "completed", nil)
        else
          finish(session, state == :ended ? "cancelled" : "failed", END_REASON_TEXT[state])
        end
      end

      # Ends the session if it is still the current, unfinished one. True if it did.
      def finish(session, status, error)
        return false unless @session.equal?(session) && open?(session)

        session.status = status
        session.error = error
        session.updated_at = Sim800c.now
        resolve_pending
        label = session.code ? "USSD #{session.code}" : "USSD from network"
        @events.info("ussd", "#{label}: #{session.response || '(no text)'}") if status == "completed"
        @events.warn("ussd", "#{label} failed: #{error}") if status == "failed"
        save(session)
        @bus.emit("ussd.ended", as_api(session))
        true
      end

      def resolve_pending
        @timer&.cancel
        @settle&.resolve
        @settle = nil
      end

      def create(code, actor)
        now = Sim800c.now
        status = code ? "pending" : "open"
        record = UssdSession.create!(code: code, status: status, messages: [], source: actor[:source],
                                     user_id: actor[:user_id], api_key_id: actor[:api_key_id], started_at: now,
                                     updated_at: now)
        ActiveSession.new(id: record.id, code: code, status: status, response: nil, error: nil, messages: [],
                          source: actor[:source], started_at: now, updated_at: now)
      end

      def load(record)
        return nil unless record

        messages = Array(record.messages).map do |m|
          { direction: m["direction"], text: m["text"], at: Time.at(0, m["at"].to_i, :millisecond).utc }
        end
        ActiveSession.new(id: record.id, code: record.code, status: record.status, response: record.response,
                          error: record.error, messages: messages, source: record.source,
                          started_at: record.started_at, updated_at: record.updated_at)
      end

      def push(session, direction, text)
        session.updated_at = Sim800c.now
        session.messages << { direction: direction, text: text, at: session.updated_at }
      end

      # Writes the session to the database and broadcasts it. Called after every change.
      def save(session)
        messages = session.messages.map do |m|
          { "direction" => m[:direction], "text" => m[:text], "at" => (m[:at].to_r * 1000).to_i }
        end
        UssdSession.where(id: session.id).update_all(status: session.status, response: session.response,
                                                     error: session.error, messages: messages,
                                                     updated_at: session.updated_at)
        @bus.emit("ussd.updated", as_api(session))
      end

      def as_api(session)
        {
          id: session.id,
          code: session.code,
          status: session.status,
          response: session.response,
          error: session.error,
          messages: session.messages.map { |m| { direction: m[:direction], text: m[:text], at: Sim800c.iso(m[:at]) } },
          source: session.source,
          startedAt: Sim800c.iso(session.started_at),
          updatedAt: Sim800c.iso(session.updated_at)
        }
      end
    end
  end
end
