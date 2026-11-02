# frozen_string_literal: true

module Sim800c
  # A voice call (history). The runtime tracks the call in progress.
  class Call < ApplicationRecord
    STATUSES = %w[dialing ringing active completed missed rejected busy no_answer cancelled failed].freeze
    ACTIVE_STATUSES = %w[dialing ringing active].freeze

    class << self
      def find_record(id)
        find_by(id: id) || raise(AppError.not_found("Call"))
      end

      # [records, total] for GET /calls.
      def search(page:, limit:, direction: nil, status: nil, q: nil)
        scope = all
        scope = scope.where(direction: direction) if direction
        scope = scope.where(status: status) if status
        scope = scope.where("LOWER(phone) LIKE ? ESCAPE '!'", "%#{sanitize_sql_like(q.downcase, '!')}%") if q.present?
        records = scope.order(started_at: :desc, id: :desc).offset((page - 1) * limit).limit(limit).to_a
        [records, scope.count]
      end

      # Deletes call records and returns the ids deleted. A call in progress is skipped.
      def delete_ids(ids)
        return [] if ids.empty?

        candidates = where(id: ids).where.not(status: ACTIVE_STATUSES).pluck(:id)
        return [] if candidates.empty?

        removed = where(id: candidates).where.not(status: ACTIVE_STATUSES).delete_all
        return candidates.sort if removed == candidates.size

        (candidates - where(id: candidates).pluck(:id)).sort
      end

      def stats
        since = Time.current.beginning_of_day
        today, missed, talk = where(started_at: since..).pick(
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(CASE WHEN status = 'missed' THEN 1 ELSE 0 END), 0)"),
          Arel.sql("COALESCE(SUM(duration), 0)")
        ).map(&:to_i)
        { today: today, missedToday: missed, talkTimeToday: talk }
      end
    end

    def as_api
      {
        id: id,
        direction: direction,
        phone: phone,
        status: status,
        endReason: end_reason,
        error: error,
        source: source,
        startedAt: iso(started_at),
        answeredAt: iso(answered_at),
        endedAt: iso(ended_at),
        duration: duration
      }
    end

    private

    def iso(time) = Sim800c.iso(time)
  end
end
