# frozen_string_literal: true

module Sim800c
  # A signed-in dashboard session. The primary key is the sha256 of the cookie's token.
  class Session < ApplicationRecord
    belongs_to :user, class_name: "Sim800c::User"

    class << self
      def ttl = Sim800c.config.auth.session_ttl

      # Returns [token, session].
      def start!(user, ip: nil, user_agent: nil)
        token = Auth.random_token(32)
        now = Time.current
        session = create!(id: Auth.sha256(token), user: user, csrf_token: Auth.random_token(24), created_at: now,
                          expires_at: now + ttl, ip: ip, user_agent: user_agent&.slice(0, 300))
        user.update_columns(last_login_at: now)
        [token, session]
      end

      # The session for a cookie token, or nil. Slides the expiry forward when past half-life.
      def authenticate(token)
        return nil if token.to_s.empty?

        session = includes(:user).find_by(id: Auth.sha256(token))
        return nil unless session

        now = Time.current
        if session.expires_at <= now
          session.delete
          return nil
        end
        session.update_columns(expires_at: now + ttl) if session.expires_at - now < ttl / 2.0
        session
      end

      def revoke(token) = where(id: Auth.sha256(token.to_s)).delete_all

      def prune! = where(expires_at: ..Time.current).delete_all
    end

    def principal
      Auth::Principal.new(type: :session, name: user.username, scopes: Set.new(user.scopes).freeze, user_id: user.id,
                          api_key_id: nil, role: user.role, session_id: id, csrf_token: csrf_token)
    end
  end
end
