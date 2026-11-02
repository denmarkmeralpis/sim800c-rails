# frozen_string_literal: true

module Sim800c
  # A USSD session: a code such as *123#, the network's replies and menu answers.
  #
  # Status: pending (waiting for the network), open (a menu waiting for a reply), then completed,
  # cancelled or failed. Sessions pushed by the network have no code and source "modem".
  class UssdSession < ApplicationRecord
    STATUSES = %w[pending open completed cancelled failed].freeze
    OPEN_STATUSES = %w[pending open].freeze
    SOURCES = %w[dashboard api modem].freeze

    class << self
      def find_record(id)
        find_by(id: id) || raise(AppError.not_found("USSD session"))
      end

      def latest = order(started_at: :desc, id: :desc).first

      # [records, total] for GET /ussd/sessions. `q` matches the code or the latest reply.
      def search(page:, limit:, status: nil, source: nil, q: nil)
        scope = all
        scope = scope.where(status: status) if status
        scope = scope.where(source: source) if source
        if q.present?
          pattern = "%#{sanitize_sql_like(q.downcase, '!')}%"
          scope = scope.where("LOWER(code) LIKE ? ESCAPE '!' OR LOWER(response) LIKE ? ESCAPE '!'", pattern, pattern)
        end
        records = scope.order(started_at: :desc, id: :desc).offset((page - 1) * limit).limit(limit).to_a
        [records, scope.count]
      end

      # Deletes sessions and returns the ids that existed. Refuses while one of them is in progress.
      def delete_ids(ids)
        return [] if ids.empty?

        in_progress = where(id: ids, status: OPEN_STATUSES).pick(:id)
        raise AppError.conflict("USSD session #{in_progress} is still in progress: cancel it first") if in_progress

        found = where(id: ids).pluck(:id)
        where(id: found).where.not(status: OPEN_STATUSES).delete_all
        (found - where(id: found).pluck(:id)).sort
      end
    end

    def as_api
      {
        id: id,
        code: code,
        status: status,
        response: response,
        error: error,
        messages: Array(messages).map do |m|
          { direction: m["direction"], text: m["text"], at: Sim800c.iso(Time.at(0, m["at"].to_i, :millisecond)) }
        end,
        source: source,
        startedAt: Sim800c.iso(started_at),
        updatedAt: Sim800c.iso(updated_at)
      }
    end
  end
end
