# frozen_string_literal: true

module Sim800c
  class Runtime
    # Sends queued SMS (with retries, multipart resume and delivery reports) and imports received
    # messages from the SIM (multipart reassembly, de-duplication). Messages are queued by web
    # processes (Sim800c::SmsMessage.enqueue), which wake this worker over RPC; it also polls.
    class SmsService
      INBOX_RESYNC = 5 * 60
      REPORT_MATCH_WINDOW = 7 * 24 * 3600

      def initialize(reactor:, bus:, manager:, config:, events:, logger:)
        @reactor = reactor
        @bus = bus
        @manager = manager
        @config = config
        @events = events
        @logger = logger
        @running = false
        @wake = nil
        @worker = nil
        @timers = []
        @concat_ref = rand(256)
        @inbox = SerialQueue.new(reactor) do |e|
          @logger.warn("[sim800c] Inbox processing failed: #{e.class}: #{e.message}")
        end
      end

      def start
        stuck = SmsMessage.where(status: "sending").update_all(status: "queued", updated_at: Time.current)
        @events.warn("sms", "Re-queued #{stuck} message(s) interrupted by a restart") if stuck.positive?

        @manager.on(:event) { |e| on_modem_event(e) }
        @manager.on(:services_ready) do
          sync_inbox
          kick
        end
        @manager.on(:status) { kick }

        @running = true
        @worker = @reactor.task { worker_loop }
        @timers << @reactor.every([60, @config.concat_timeout].min) { flush_stale_fragments }
        @timers << @reactor.every(INBOX_RESYNC) { sync_inbox if @manager.can_operate? }
      end

      # Call inside a task.
      def stop
        @running = false
        @timers.each(&:cancel)
        kick
        @reactor.await(@worker) if @worker
        @inbox.drain
      end

      # Wakes the send worker (new messages, modem status change).
      def kick
        wake = @wake
        @wake = nil
        wake&.call
      end

      # Imports every message stored on the SIM (catches anything received while offline).
      # Returns a Promise that settles once done.
      def sync_inbox
        @inbox.enqueue do
          stored = @manager.modem.list_messages
          @logger.info("[sim800c] Importing #{stored.size} message(s) from SIM storage") if stored.any?
          stored.each { |m| import_stored(m) }
        end
      end

      private

      # -------------------------------------------------------------------------------------------
      # Outbound
      # -------------------------------------------------------------------------------------------

      def sleep_until_kicked(seconds)
        promise = Promise.new
        timer = nil
        done = lambda do
          timer&.cancel
          @wake = nil if @wake.equal?(done)
          promise.resolve
        end
        timer = @reactor.after(seconds) { done.call } if seconds
        @wake = done
        @reactor.await(promise)
      end

      def worker_loop
        while @running
          unless @manager.can_operate?
            sleep_until_kicked(nil)
            next
          end
          now = Time.current
          row = SmsMessage.where(status: "queued").where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
                          .order(priority: :desc, id: :asc).first
          unless row
            due = SmsMessage.where(status: "queued").minimum(:next_attempt_at)
            wait = @config.queue_poll_interval.to_f
            wait = (due - now).clamp(0, wait) if due
            sleep_until_kicked(wait)
            next
          end
          begin
            send_one(row)
          rescue StandardError => e
            @logger.error("[sim800c] Unexpected error in SMS worker (message ##{row.id}): #{e.class}: #{e.message}\n" \
                          "#{e.backtrace&.first(8)&.join("\n")}")
            sleep_until_kicked(1)
          end
        end
      end

      def send_one(row)
        claimed = SmsMessage.where(id: row.id, status: "queued")
                            .update_all(["status = 'sending', attempts = attempts + 1, updated_at = ?", Time.current])
        return if claimed.zero?

        # Re-read: the message may have been cancelled and re-queued since it was selected.
        row = SmsMessage.find(row.id)
        emit_change(row.id, false)
        initial = row.refs ? row.refs.deep_dup : { "concatRef" => next_concat_ref, "parts" => [] }
        save_refs(row.id, initial) unless row.refs
        begin
          submission = PDU.encode_submit(to: row.phone, text: row.body, status_report: @config.delivery_reports,
                                         reference: initial["concatRef"], max_parts: @config.max_parts)
          # Resume multipart messages: parts already accepted by the network are not resent.
          (initial["parts"].size...submission.parts.size).each do |i|
            mr = @manager.modem.send_pdu(submission.parts[i], @config.send_timeout)
            # Delivery reports for earlier parts may have been recorded meanwhile, so re-read first.
            refs = read_refs(row.id) || initial
            refs["parts"] << { "mr" => mr, "st" => "pending" }
            save_refs(row.id, refs)
          end
          now = Time.current
          SmsMessage.where(id: row.id).update_all(status: "sent", sent_at: now, error: nil, next_attempt_at: nil,
                                                  updated_at: now)
          @logger.info("[sim800c] SMS ##{row.id} sent to #{row.phone} (#{submission.parts.size} part(s))")
          emit_change(row.id, true)
          settle_delivery(row.id)
        rescue StandardError => e
          handle_send_failure(row, e)
        end
      end

      def read_refs(id) = SmsMessage.where(id: id).pick(:refs)

      def save_refs(id, refs)
        SmsMessage.where(id: id).update_all(refs: refs)
      end

      # Moves a sent message to delivered / failed once the per-part delivery reports allow it.
      def settle_delivery(id, discharged_at = Time.current)
        row = SmsMessage.find_by(id: id)
        return unless row && row.status == "sent" && row.refs

        parts = row.refs["parts"]
        failed = parts.find { |p| p["st"] == "failed" }
        now = Time.current
        if failed
          SmsMessage.where(id: id, status: "sent")
                    .update_all(status: "failed", error: "Delivery failed: #{failed['err'] || 'rejected by the network'}",
                                updated_at: now)
          @events.warn("sms", "SMS ##{id} to #{row.phone} was not delivered: #{failed['err'] || 'unknown reason'}")
        elsif parts.size == row.parts && parts.all? { |p| p["st"] == "delivered" }
          SmsMessage.where(id: id, status: "sent").update_all(status: "delivered", delivered_at: discharged_at,
                                                              updated_at: now)
        else
          return
        end
        emit_change(id, true)
      end

      def handle_send_failure(row, error)
        message = error.message
        now = Time.current
        attempts = row.attempts

        # A dropped modem link is not the message's fault: requeue without spending an attempt.
        if error.is_a?(AT::CommandError) && error.kind == :disconnected
          SmsMessage.where(id: row.id)
                    .update_all(["status = 'queued', attempts = attempts - 1, error = ?, updated_at = ?",
                                 "Modem disconnected while sending — will retry: #{message}", now])
          emit_change(row.id, false)
          return
        end

        retryable = !error.is_a?(PDU::Error) && AT.retryable_sms_error?(error)
        if retryable && attempts < @config.max_attempts
          delay = @config.retry_base * (2**(attempts - 1))
          SmsMessage.where(id: row.id).update_all(status: "queued", error: message, next_attempt_at: now + delay,
                                                  updated_at: now)
          @events.warn("sms", "SMS ##{row.id} to #{row.phone} failed (attempt #{attempts}/#{@config.max_attempts}): " \
                              "#{message} — retrying in #{delay.round}s")
          emit_change(row.id, false)
        else
          SmsMessage.where(id: row.id).update_all(status: "failed", error: message, next_attempt_at: nil, updated_at: now)
          @events.error("sms", "SMS ##{row.id} to #{row.phone} failed permanently: #{message}")
          emit_change(row.id, true)
        end
      end

      def next_concat_ref
        @concat_ref = (@concat_ref + 1) % 256
      end

      # -------------------------------------------------------------------------------------------
      # Inbound
      # -------------------------------------------------------------------------------------------

      def on_modem_event(event)
        case event[:type]
        when :sms_stored, :status_report_stored
          @inbox.enqueue do
            stored = @manager.modem.read_message(event[:index])
            import_stored(stored) if stored
          end
        when :sms_direct, :status_report
          @inbox.enqueue { ingest_pdu(event[:pdu], event[:length]) }
        end
      end

      # Persists a SIM-stored message, then frees its slot. Not deleted if persisting fails.
      def import_stored(stored)
        return if ingest_pdu(stored[:pdu], stored[:length]) == :keep

        begin
          @manager.modem.delete_message(stored[:index])
        rescue StandardError => e
          @logger.warn("[sim800c] Could not delete message #{stored[:index]} from SIM: #{e.message}")
        end
      end

      def ingest_pdu(pdu, length)
        decoded = begin
          PDU.decode(pdu, length)
        rescue PDU::Error => e
          @events.warn("sms", "Received an undecodable message: #{e.message}", { pdu: pdu })
          insert_inbound(phone: "unknown", body: "[Undecodable message] #{pdu}", encoding: nil, parts: 1, smsc: nil,
                         sent_at: nil, hash: sha1(pdu))
          return :done
        end
        case decoded.type
        when :deliver then ingest_deliver(decoded, sha1(pdu))
        when :status_report then apply_status_report(decoded)
        else return :keep # SMS-SUBMIT drafts saved on the SIM by a phone: leave them alone
        end
        :done
      end

      def ingest_deliver(deliver, hash)
        concat = deliver.concat
        if concat.nil? || concat.total <= 1
          insert_inbound(phone: deliver.sender, body: deliver.text, encoding: deliver.encoding, parts: 1,
                         smsc: deliver.smsc, sent_at: deliver.timestamp, hash: hash)
          return
        end

        group = { phone: deliver.sender, ref: concat.ref, total: concat.total }
        complete = SmsFragment.transaction do
          # insert_all skips a part that is already stored (re-read from the SIM).
          SmsFragment.insert_all([group.merge(seq: concat.seq, body: deliver.text, encoding: deliver.encoding,
                                              smsc: deliver.smsc, sent_at: deliver.timestamp,
                                              received_at: Time.current, pdu_hash: hash)])
          fragments = SmsFragment.where(group).order(:seq).to_a
          next nil if fragments.size < concat.total

          SmsFragment.where(group).delete_all
          fragments
        end
        insert_assembled(complete, false) if complete
      end

      # Emits multipart messages whose remaining parts never arrived, marking the gaps.
      def flush_stale_fragments
        cutoff = Time.current - @config.concat_timeout
        groups = SmsFragment.group(:phone, :ref, :total).having("MIN(received_at) < ?", cutoff).pluck(:phone, :ref, :total)
        groups.each do |phone, ref, total|
          group = { phone: phone, ref: ref, total: total }
          fragments = SmsFragment.transaction do
            rows = SmsFragment.where(group).order(:seq).to_a
            SmsFragment.where(group).delete_all
            rows
          end
          next if fragments.empty?

          @events.warn("sms", "Multipart message from #{phone} incomplete (#{fragments.size}/#{total} parts)")
          insert_assembled(fragments, true)
        end
      end

      def insert_assembled(fragments, partial)
        first = fragments.first
        body = +""
        i = 0
        (1..first.total).each do |seq|
          if fragments[i]&.seq == seq
            body << fragments[i].body
            i += 1
          elsif partial
            body << " […missing part…] "
          end
        end
        insert_inbound(phone: first.phone, body: body, encoding: first.encoding, parts: first.total, smsc: first.smsc,
                       sent_at: first.sent_at, hash: sha1(fragments.map(&:pdu_hash).join(":")))
      end

      def insert_inbound(phone:, body:, encoding:, parts:, smsc:, sent_at:, hash:)
        now = Time.current
        record = SmsMessage.create!(direction: "inbound", phone: phone, body: body, status: "received",
                                    encoding: encoding, parts: parts, smsc: smsc, pdu_hash: hash, source: "modem",
                                    created_at: now, updated_at: now, received_at: sent_at)
        @logger.info("[sim800c] SMS ##{record.id} received from #{record.phone} (#{record.parts} part(s))")
        @bus.emit("sms.received", record.as_api)
      rescue ActiveRecord::RecordNotUnique
        nil # duplicate (the message was re-read from the SIM)
      end

      def apply_status_report(report)
        if report.state == "pending"
          @logger.debug("[sim800c] Interim delivery report ignored (mr #{report.reference}, status #{report.status})")
          return
        end
        # Reports can overtake the submission of later parts, so messages still sending are candidates too.
        candidates = SmsMessage.where(direction: "outbound", status: %w[queued sending sent]).where.not(refs: nil)
                               .where("updated_at > ?", Time.current - REPORT_MATCH_WINDOW)
                               .order(id: :desc).limit(500).select(:id, :phone, :refs)
        candidates.each do |row|
          next unless Phone.match?(row.phone, report.recipient)

          refs = row.refs
          part = refs["parts"]&.find { |p| p["mr"] == report.reference && p["st"] == "pending" }
          next unless part

          part["st"] = report.state
          part["err"] = report.status_text if report.state == "failed"
          save_refs(row.id, refs)
          settle_delivery(row.id, report.discharged_at)
          return
        end
        @logger.debug("[sim800c] Delivery report did not match any message (mr #{report.reference}, " \
                      "#{report.recipient})")
      end

      def sha1(string) = OpenSSL::Digest::SHA1.hexdigest(string.upcase)

      def emit_change(id, status_changed)
        record = SmsMessage.find_by(id: id)&.as_api
        return nil unless record

        @bus.emit("sms.updated", record)
        @bus.emit("sms.status", record) if status_changed
        record
      end
    end
  end
end
