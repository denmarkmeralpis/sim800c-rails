# frozen_string_literal: true

module Sim800c
  # Base for the JSON API: authentication (API key or dashboard session + CSRF token), scopes,
  # API key rate limiting, JSON body parsing and the {"error": {code, message, details}} envelope.
  class ApiController < ActionController::API
    SESSION_COOKIE = "sim800c_session"
    SAFE_METHODS = %w[GET HEAD OPTIONS].freeze
    MAX_BODY = 100 * 1024

    rescue_from StandardError, with: :render_internal_error
    rescue_from AT::CommandError, with: :render_modem_error
    rescue_from AppError, with: :render_app_error

    private

    attr_reader :principal, :current_user

    # -- authentication ------------------------------------------------------------------------------

    def authenticate!
      key = api_key_from_request
      if key
        @principal = ApiKey.authenticate(key) or raise AppError.unauthorized("Invalid or revoked API key")
        rate_limit_api_key!
        return
      end

      session = Session.authenticate(request.cookies[SESSION_COOKIE])
      raise AppError.unauthorized unless session

      unless SAFE_METHODS.include?(request.request_method)
        csrf = request.headers["X-CSRF-Token"].to_s
        unless ActiveSupport::SecurityUtils.secure_compare(csrf, session.csrf_token)
          raise AppError.new(403, "csrf_failed", "Missing or invalid CSRF token")
        end
      end
      @principal = session.principal
      @current_user = session.user
    end

    def api_key_from_request
      header = request.headers["X-API-Key"].to_s.strip
      return header unless header.empty?

      m = /\ABearer\s+(.+)\z/i.match(request.headers["Authorization"].to_s)
      m && m[1].strip
    end

    def require_scope!(*scopes)
      missing = scopes.reject { |s| principal&.scope?(s) }
      raise AppError.forbidden("Missing required permission: #{missing.join(', ')}") if missing.any?
    end

    # Endpoints that only a signed-in dashboard user (not an API key) may call.
    def require_session!
      raise AppError.forbidden("This endpoint requires a dashboard session") unless principal&.session?
    end

    def rate_limit_api_key!
      limiter = Web::RateLimiter.new("api", limit: Sim800c.config.auth.api_rate_limit_per_min, period: 60)
      result = limiter.hit("key:#{principal.api_key_id}")
      limiter.headers(result).each { |name, value| response.set_header(name, value) }
      raise AppError.new(429, "rate_limited", "API rate limit exceeded") unless result.allowed
    end

    # -- session cookie ------------------------------------------------------------------------------

    def cookie_path = request.script_name.presence || "/"

    def secure_cookies?
      configured = Sim800c.config.auth.cookie_secure
      configured.nil? ? request.ssl? : configured
    end

    def set_session_cookie(token, max_age)
      response.set_cookie(SESSION_COOKIE, value: token, path: cookie_path, httponly: true, same_site: :strict,
                                          secure: secure_cookies?, max_age: max_age.to_i.to_s)
    end

    def clear_session_cookie = set_session_cookie("", 0)

    # -- input ---------------------------------------------------------------------------------------

    # The parsed JSON body ({} when empty). Never touches `params`, so bad JSON is a clean 400.
    def body
      return @body if defined?(@body)

      if request.content_length.to_i > MAX_BODY
        raise AppError.new(413, "payload_too_large", "Request body is too large")
      end

      raw = request.raw_post.to_s
      raise AppError.new(413, "payload_too_large", "Request body is too large") if raw.bytesize > MAX_BODY

      @body = raw.strip.empty? ? {} : JSON.parse(raw)
    rescue JSON::ParserError, EncodingError
      raise AppError.new(400, "invalid_json", "Request body is not valid JSON")
    end

    def body_validation = Web::Validation.new(body)

    def query_validation = Web::Validation.new(request.query_parameters.to_h, coerce: true)

    # The :id path segment as a positive integer.
    def id_param
      v = Web::Validation.new({ "id" => request.path_parameters[:id] }, coerce: true)
      id = v.integer("id", min: 1)
      v.validate!
      id
    end

    # -- shared helpers ------------------------------------------------------------------------------

    def actor = principal.actor

    # Writes a user-visible event log entry and returns its id (to pass to Gateway.notify).
    def log_event(level, category, message, data = nil)
      Sim800c.logger.public_send(level, "[sim800c] [#{category}] #{message}")
      EventLogEntry.record!(level, category, message, data).id
    rescue StandardError => e
      Sim800c.logger.error("[sim800c] Failed to persist event log entry: #{e.message}")
      nil
    end

    # Creates the admin from config.auth.admin_password the first time it is needed in this process.
    def ensure_configured_admin
      ApiController.ensure_configured_admin
    end

    ADMIN_LOCK = Mutex.new
    private_constant :ADMIN_LOCK

    def self.ensure_configured_admin
      return if @admin_checked

      ADMIN_LOCK.synchronize do
        return if @admin_checked

        auth = Sim800c.config.auth
        User.ensure_admin!(auth.admin_username, auth.admin_password)
        @admin_checked = true
      end
    rescue StandardError => e
      Sim800c.logger.error("[sim800c] Could not create the configured admin account: #{e.message}")
    end

    # -- errors --------------------------------------------------------------------------------------

    def render_error(status, code, message, details = nil)
      render json: { error: { code: code, message: message, details: details }.compact }, status: status
    end

    def render_app_error(error)
      render_error(error.status, error.code, error.message, error.details)
    end

    def render_modem_error(error)
      render_app_error(Runtime::Operations.error_for(error))
    end

    def render_internal_error(error)
      Sim800c.logger.error("[sim800c] Unhandled request error on #{request.request_method} #{request.path}: " \
                           "#{error.class}: #{error.message}\n#{error.backtrace&.first(10)&.join("\n")}")
      render_error(500, "internal_error", "Internal server error")
    end
  end
end
