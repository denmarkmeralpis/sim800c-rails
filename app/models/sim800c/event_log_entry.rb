# frozen_string_literal: true

module Sim800c
  # Persistent, user-visible log of modem / SMS / call events and errors (the last 5000 are kept).
  class EventLogEntry < ApplicationRecord
    LEVELS = %w[info warn error].freeze
    MAX_ENTRIES = 5000
    PRUNE_EVERY = 100

    @inserts = 0
    @inserts_lock = Mutex.new

    class << self
      def record!(level, category, message, data = nil)
        entry = create!(level: level.to_s, category: category.to_s, message: message.to_s, data: data,
                        created_at: Time.current)
        prune! if (@inserts_lock.synchronize { @inserts += 1 } % PRUNE_EVERY).zero?
        entry
      end

      def prune!
        max = maximum(:id)
        where(id: ..(max - MAX_ENTRIES)).delete_all if max && max > MAX_ENTRIES
      end

      def recent(limit:, level: nil, category: nil, before: nil)
        scope = order(id: :desc).limit(limit)
        scope = scope.where(level: level) if level
        scope = scope.where(category: category) if category
        scope = scope.where(id: ...before) if before
        scope.to_a
      end
    end

    def as_api
      { id: id, level: level, category: category, message: message, data: data, createdAt: Sim800c.iso(created_at) }
    end
  end
end
