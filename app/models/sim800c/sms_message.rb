# frozen_string_literal: true

module Sim800c
  # An outbound (queued by the API or dashboard, sent by the runtime) or inbound (received) SMS.
  #
  # Status flow: queued -> sending -> sent -> delivered, or failed / cancelled; inbound: received.
  class SmsMessage < ApplicationRecord
    STATUSES = %w[queued sending sent delivered failed cancelled received].freeze
    # Puts a message back in the queue with a fresh set of attempts.
    REQUEUE = { status: "queued", attempts: 0, error: nil, next_attempt_at: nil, refs: nil }.freeze

    class << self
      # Queues a message to each recipient. Returns [records, replayed].
      #
      # With an Idempotency-Key (`idempotency: { owner:, key: }`) the key is stored with the ids of the
      # records it created, in the same transaction, so a request that fails validation does not use
      # it up. Repeating the same request within 24 h returns the current state of those records;
      # reusing the key for a different request is a 409.
      def enqueue(to:, text:, source:, priority: nil, user_id: nil, api_key_id: nil, idempotency: nil)
        # The fingerprint covers the parsed request, so "a,b" and ["a","b"] are the same request.
        idem = idempotency && idempotency.merge(hash: Auth.sha256(JSON.generate([to, text, priority || 0])))
        if idem && (replay = replay_idempotent(idem))
          return [replay, true]
        end

        raise AppError.bad_request("Message text is required") if text.to_s.strip.empty?

        plan = PDU.plan_message(text)
        max_parts = Sim800c.config.sms.max_parts
        if plan.parts.size > max_parts
          raise AppError.bad_request("Message is too long: #{plan.parts.size} SMS parts needed, maximum is #{max_parts}")
        end

        recipients = to.map { |n| Phone.normalize(n) }.uniq
        raise AppError.bad_request("At least one recipient is required") if recipients.empty?

        now = Time.current
        ids = transaction do
          created = recipients.map do |phone|
            create!(direction: "outbound", phone: phone, body: text, status: "queued", encoding: plan.encoding,
                    parts: plan.parts.size, priority: priority || 0, source: source, user_id: user_id,
                    api_key_id: api_key_id, created_at: now, updated_at: now).id
          end
          if idem
            # An expired row for the same key may not have been pruned yet. A live one (a concurrent
            # request with the same key) makes the insert fail, and that request is replayed below.
            IdempotencyKey.where(owner: idem[:owner], idempotency_key: idem[:key])
                          .where(created_at: ..(now - IdempotencyKey::TTL)).delete_all
            IdempotencyKey.create!(owner: idem[:owner], idempotency_key: idem[:key], request_hash: idem[:hash],
                                   sms_ids: created, created_at: now)
          end
          created
        end
        [where(id: ids).order(:id).to_a, false]
      rescue ActiveRecord::RecordNotUnique
        raise unless idem && (replay = replay_idempotent(idem))

        [replay, true]
      end

      # Re-queues a failed or cancelled outbound message.
      def retry!(id)
        record = find_record(id)
        unless record.direction == "outbound" && %w[failed cancelled].include?(record.status)
          raise AppError.conflict("Only failed or cancelled outbound messages can be retried")
        end

        changed = where(id: id, direction: "outbound", status: %w[failed cancelled])
                  .update_all(REQUEUE.merge(updated_at: Time.current))
        raise AppError.conflict("Only failed or cancelled outbound messages can be retried") if changed.zero?

        find(id)
      end

      # Re-queues every failed outbound message. Returns their ids, ascending.
      def retry_failed!
        ids = where(direction: "outbound", status: "failed").pluck(:id)
        return [] if ids.empty?

        where(id: ids, status: "failed").update_all(REQUEUE.merge(updated_at: Time.current))
        where(id: ids, status: "queued", attempts: 0).pluck(:id).sort
      end

      def cancel!(id)
        changed = where(id: id, status: "queued").update_all(status: "cancelled", next_attempt_at: nil,
                                                             updated_at: Time.current)
        if changed.zero?
          find_record(id)
          raise AppError.conflict("Only queued messages can be cancelled")
        end
        find(id)
      end

      # Marks inbound messages read or unread. Returns how many changed.
      def mark_read(ids, read)
        return 0 if ids.empty?

        scope = where(direction: "inbound", id: ids)
        scope = read ? scope.where(read_at: nil) : scope.where.not(read_at: nil)
        now = Time.current
        scope.update_all(read_at: read ? now : nil, updated_at: now)
      end

      # Deletes messages and returns the ids that were deleted. Messages being transmitted are skipped.
      def delete_ids(ids)
        return [] if ids.empty?

        candidates = where(id: ids).where.not(status: "sending").pluck(:id)
        return [] if candidates.empty?

        removed = where(id: candidates).where.not(status: "sending").delete_all
        return candidates.sort if removed == candidates.size

        # Some started sending meanwhile: report only the rows that are really gone.
        (candidates - where(id: candidates).pluck(:id)).sort
      end

      # [records, total] for GET /sms.
      def search(page:, limit:, direction: nil, status: nil, phone: nil, q: nil, unread: false)
        scope = all
        scope = scope.where(direction: direction) if direction
        scope = scope.where(status: status) if status
        scope = scope.where(phone: phone) if phone
        scope = scope.where(direction: "inbound", read_at: nil) if unread
        if q.present?
          pattern = "%#{sanitize_sql_like(q.downcase, '!')}%"
          scope = scope.where("LOWER(phone) LIKE ? ESCAPE '!' OR LOWER(body) LIKE ? ESCAPE '!'", pattern, pattern)
        end
        records = scope.order(created_at: :desc, id: :desc).offset((page - 1) * limit).limit(limit).to_a
        [records, scope.count]
      end

      # Counters for the dashboard, in one pass. "Today" starts at midnight in the app's time zone.
      def stats
        since = Time.current.beginning_of_day
        sql = sanitize_sql_array([<<~SQL.squish, { since: since }])
          COUNT(*),
          COALESCE(SUM(CASE WHEN direction = 'inbound' AND read_at IS NULL THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN direction = 'inbound' AND created_at >= :since THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN direction = 'outbound' AND status IN ('sent', 'delivered') AND sent_at >= :since
                            THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN direction = 'outbound' AND status = 'failed' AND updated_at >= :since
                            THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN status IN ('queued', 'sending') THEN 1 ELSE 0 END), 0)
        SQL
        total, unread, received, sent, failed, queued = unscoped.pick(Arel.sql(sql)).map(&:to_i)
        { unread: unread, receivedToday: received, sentToday: sent, failedToday: failed, queued: queued, total: total }
      end

      def find_record(id)
        find_by(id: id) || raise(AppError.not_found("Message"))
      end

      private

      # The records an earlier request with this key created (minus deleted ones), or nil if the key is new.
      def replay_idempotent(idem)
        row = IdempotencyKey.where(owner: idem[:owner], idempotency_key: idem[:key])
                            .where("created_at > ?", Time.current - IdempotencyKey::TTL).first
        return nil unless row

        unless row.request_hash == idem[:hash]
          raise AppError.new(409, "idempotency_key_reused", "This Idempotency-Key was already used with a different request")
        end

        ids = Array(row.sms_ids)
        found = where(id: ids).index_by(&:id)
        ids.filter_map { |id| found[id] }
      end
    end

    def outbound? = direction == "outbound"

    def as_api
      {
        id: id,
        direction: direction,
        phone: phone,
        body: body,
        status: status,
        encoding: encoding,
        parts: parts,
        priority: priority,
        attempts: attempts,
        error: error,
        source: source,
        read: outbound? || !read_at.nil?,
        createdAt: iso(created_at),
        updatedAt: iso(updated_at),
        nextAttemptAt: status == "queued" ? iso(next_attempt_at) : nil,
        sentAt: iso(sent_at),
        deliveredAt: iso(delivered_at),
        receivedAt: iso(received_at),
        smsc: smsc
      }
    end

    private

    def iso(time) = Sim800c.iso(time)
  end
end
