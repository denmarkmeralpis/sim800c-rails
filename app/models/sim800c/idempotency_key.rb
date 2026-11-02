# frozen_string_literal: true

module Sim800c
  # A client-supplied Idempotency-Key for POST /sms, with the ids of the messages it created.
  class IdempotencyKey < ApplicationRecord
    TTL = 24 * 3600

    # Deletes keys older than 24 h. Returns how many were removed.
    def self.prune!
      where(created_at: ..(Time.current - TTL)).delete_all
    end
  end
end
