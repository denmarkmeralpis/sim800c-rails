# frozen_string_literal: true

module Sim800c
  class Error < StandardError; end

  class TimeoutError < Error; end

  class ConfigError < Error; end

  # An error with an HTTP status and a stable machine-readable code, rendered by the API as
  # {"error": {"code", "message", "details"}}.
  class AppError < Error
    attr_reader :status, :code, :details

    def initialize(status, code, message, details = nil)
      super(message)
      @status = status
      @code = code
      @details = details
    end

    def to_h
      { status: status, code: code, message: message, details: details }.compact
    end

    class << self
      def bad_request(message, details = nil) = new(400, "bad_request", message, details)
      def unauthorized(message = "Authentication required") = new(401, "unauthorized", message)

      def forbidden(message = "You do not have permission to perform this action")
        new(403, "forbidden", message)
      end

      def not_found(what = "Resource") = new(404, "not_found", "#{what} not found")
      def conflict(message) = new(409, "conflict", message)
      def modem_unavailable(message) = new(503, "modem_unavailable", message)
    end
  end
end
