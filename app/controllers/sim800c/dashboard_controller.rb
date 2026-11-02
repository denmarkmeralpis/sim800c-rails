# frozen_string_literal: true

module Sim800c
  # Serves the dashboard page; its scripts, styles and fonts come from the engine's public/ folder.
  class DashboardController < ActionController::Base
    CONTENT_SECURITY_POLICY = [
      "default-src 'self'",
      "script-src 'self'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data:",
      "connect-src 'self'",
      "font-src 'self'",
      "object-src 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "frame-ancestors 'none'"
    ].join("; ")

    content_security_policy false
    skip_forgery_protection
    layout false

    after_action :security_headers

    def show
      @base = request.script_name.to_s.chomp("/")
      @assets = "#{@base}#{Web::Assets::PREFIX}"
      response.set_header("cache-control", "no-cache")
      render :show, formats: :html
    end

    private

    def security_headers
      response.set_header("content-security-policy", CONTENT_SECURITY_POLICY)
      response.set_header("x-content-type-options", "nosniff")
      response.set_header("x-frame-options", "DENY")
      response.set_header("referrer-policy", "no-referrer")
      response.set_header("cross-origin-opener-policy", "same-origin")
      response.set_header("cross-origin-resource-policy", "same-origin")
    end
  end
end
