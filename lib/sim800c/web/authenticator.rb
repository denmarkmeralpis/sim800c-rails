# frozen_string_literal: true

module Sim800c
  module Web
    # Authenticates an API request: an API key (X-API-Key or Authorization: Bearer) or the dashboard
    # session cookie. Cookie-authenticated writes must echo the session's CSRF token in X-CSRF-Token.
    # API keys are rate limited.
    module Authenticator
      SESSION_COOKIE = "sim800c_session"
      SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

      Result = Data.define(:principal, :user, :rate_limit_headers)

      module_function

      # Returns a Result or raises AppError (401, 403 csrf_failed, 429).
      def authenticate(request)
        key = api_key(request)
        return authenticate_api_key(key) if key

        session = Session.authenticate(request.cookies[SESSION_COOKIE])
        raise AppError.unauthorized unless session

        unless SAFE_METHODS.include?(request.request_method)
          csrf = request.headers["X-CSRF-Token"].to_s
          unless ActiveSupport::SecurityUtils.secure_compare(csrf, session.csrf_token)
            raise AppError.new(403, "csrf_failed", "Missing or invalid CSRF token")
          end
        end
        Result.new(principal: session.principal, user: session.user, rate_limit_headers: {})
      end

      def api_key(request)
        header = request.headers["X-API-Key"].to_s.strip
        return header unless header.empty?

        m = /\ABearer\s+(.+)\z/i.match(request.headers["Authorization"].to_s)
        m && m[1].strip
      end

      def authenticate_api_key(key)
        principal = ApiKey.authenticate(key) or raise AppError.unauthorized("Invalid or revoked API key")
        limiter = RateLimiter.new("api", limit: Sim800c.config.auth.api_rate_limit_per_min, period: 60)
        result = limiter.hit("key:#{principal.api_key_id}")
        headers = limiter.headers(result)
        raise RateLimited.new(headers) unless result.allowed

        Result.new(principal: principal, user: nil, rate_limit_headers: headers)
      end

      # 429 that carries the RateLimit headers.
      class RateLimited < AppError
        attr_reader :headers

        def initialize(headers)
          super(429, "rate_limited", "API rate limit exceeded")
          @headers = headers
        end
      end
    end
  end
end
