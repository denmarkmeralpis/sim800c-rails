# frozen_string_literal: true

module Sim800c
  module Api
    # Sign-in, first-time setup, sign-out, the current principal and password changes.
    class AuthController < ApiController
      before_action :ensure_configured_admin
      before_action :authenticate!, only: %i[me password]
      before_action :check_login_rate_limit, only: %i[login setup]

      def login
        v = body_validation
        username = v.string("username", trim: true, min: 1, max: 100)
        password = v.string("password", min: 1, max: 200)
        v.validate!
        sign_in(username, password)
      end

      # Until an account exists, anyone who can reach the dashboard may create the admin.
      # config.auth.admin_password skips this step.
      def setup_status
        render json: { required: User.needs_setup?, username: Sim800c.config.auth.admin_username }
      end

      def setup
        v = body_validation
        username = v.string("username", trim: true, min: 3, max: 40)
        password = v.string("password", min: 8, max: 200, min_message: "Password must be at least 8 characters")
        v.validate!
        user = User.setup_admin!(username, password)
        log_event(:info, "auth", "Admin account \"#{user.username}\" created during first-time setup", { ip: request.remote_ip })
        sign_in(username, password)
      end

      def logout
        token = request.cookies[SESSION_COOKIE]
        Session.revoke(token) if token.present?
        clear_session_cookie
        head :no_content
      end

      def me
        if principal.api_key?
          render json: { apiKey: { id: principal.api_key_id, name: principal.name }, scopes: principal.scopes.to_a }
        else
          render json: { user: current_user.as_api, csrfToken: principal.csrf_token, scopes: principal.scopes.to_a }
        end
      end

      def password
        unless principal.session?
          raise AppError.new(403, "forbidden", "Password changes require a dashboard session")
        end

        v = body_validation
        current = v.string("currentPassword", min: 1)
        new_password = v.string("newPassword", min: 8, max: 200, min_message: "New password must be at least 8 characters")
        v.validate!
        current_user.change_password!(current, new_password, principal.session_id)
        log_event(:info, "auth", "User \"#{principal.name}\" changed their password")
        head :no_content
      end

      private

      def login_limiter
        auth = Sim800c.config.auth
        Web::RateLimiter.new("login", limit: auth.login_rate_limit, period: auth.login_rate_period)
      end

      # Only failed attempts count (10 per 15 minutes per address by default).
      def check_login_rate_limit
        return unless login_limiter.exceeded?(request.remote_ip)

        raise AppError.new(429, "rate_limited", "Too many failed sign-in attempts. Try again in a few minutes.")
      end

      def sign_in(username, password)
        user = User.authenticate(username, password)
        unless user
          login_limiter.hit(request.remote_ip)
          raise AppError.unauthorized("Invalid username or password")
        end

        token, session = Session.start!(user, ip: request.remote_ip, user_agent: request.user_agent)
        log_event(:info, "auth", "User \"#{user.username}\" signed in", { ip: request.remote_ip })
        set_session_cookie(token, Session.ttl)
        render json: {
          user: user.reload.as_api,
          csrfToken: session.csrf_token,
          scopes: user.scopes,
          expiresAt: Sim800c.iso(session.expires_at)
        }
      end
    end
  end
end
