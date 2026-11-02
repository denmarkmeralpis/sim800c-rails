# frozen_string_literal: true

module Sim800c
  # A scoped key for the REST API. Only its sha256 is stored; the key is shown once.
  class ApiKey < ApplicationRecord
    class << self
      # Returns [key, api_key].
      def generate!(name, scopes, created_by_id)
        scopes = Array(scopes).map(&:to_s).uniq
        invalid = scopes - Auth::API_KEY_SCOPES
        raise AppError.bad_request("Invalid scopes for an API key: #{invalid.join(', ')}") if invalid.any?
        raise AppError.bad_request("An API key needs at least one scope") if scopes.empty?

        key = Auth::API_KEY_PREFIX + Auth.random_token(24)
        record = create!(name: name, prefix: key[0, Auth::API_KEY_PREFIX.size + 6], key_hash: Auth.sha256(key),
                         scopes: scopes, created_by_id: created_by_id, created_at: Time.current)
        [key, record]
      end

      # Active keys first, newest first.
      def listing
        order(Arel.sql("CASE WHEN revoked_at IS NULL THEN 0 ELSE 1 END"), created_at: :desc, id: :desc)
      end

      # The principal for a valid, unrevoked key, or nil.
      def authenticate(key)
        return nil unless key.to_s.start_with?(Auth::API_KEY_PREFIX)

        record = find_by(key_hash: Auth.sha256(key), revoked_at: nil)
        return nil unless record

        now = Time.current
        record.update_columns(last_used_at: now) if record.last_used_at.nil? || now - record.last_used_at > 60
        record.principal
      end
    end

    def revoke!
      update!(revoked_at: Time.current) unless revoked_at
      self
    end

    def principal
      Auth::Principal.new(type: :api_key, name: name, scopes: Set.new(scopes).freeze, user_id: nil, api_key_id: id,
                          role: nil, session_id: nil, csrf_token: nil)
    end

    def as_api
      { id: id, name: name, prefix: prefix, scopes: scopes, createdAt: iso(created_at), lastUsedAt: iso(last_used_at),
        revokedAt: iso(revoked_at) }
    end

    private

    def iso(time) = Sim800c.iso(time)
  end
end
