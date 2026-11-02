# frozen_string_literal: true

require "openssl"
require "securerandom"
require "set"

module Sim800c
  # Scopes, roles, password hashing and the authenticated principal.
  module Auth
    SCOPES = %w[sms:read sms:send sms:delete calls:read calls:write modem:read modem:write admin].freeze
    # API keys cannot manage users or keys; that stays in the dashboard.
    API_KEY_SCOPES = (SCOPES - ["admin"]).freeze
    ROLES = %w[admin operator viewer].freeze
    ROLE_SCOPES = {
      "admin" => SCOPES,
      "operator" => %w[sms:read sms:send sms:delete calls:read calls:write modem:read].freeze,
      "viewer" => %w[sms:read calls:read modem:read].freeze
    }.freeze
    API_KEY_PREFIX = "smsgw_"
    USERNAME_FORMAT = /\A[a-zA-Z0-9._-]{3,40}\z/
    SCRYPT = { n: 16_384, r: 8, p: 1, length: 64 }.freeze

    # type: :session or :api_key; scopes: a frozen Set of scope strings.
    Principal = Data.define(:type, :name, :scopes, :user_id, :api_key_id, :role, :session_id, :csrf_token) do
      def session? = type == :session
      def api_key? = type == :api_key
      def scope?(scope) = scopes.include?(scope)

      # Who performed an action, as recorded on SMS, calls and USSD sessions.
      def actor
        { source: api_key? ? "api" : "dashboard", user_id: user_id, api_key_id: api_key_id }
      end

      # Idempotency-Keys are separate for each API key and dashboard user.
      def idempotency_owner = api_key? ? "key:#{api_key_id}" : "user:#{user_id}"
    end

    module_function

    def sha256(string) = OpenSSL::Digest::SHA256.hexdigest(string)

    def random_token(bytes) = SecureRandom.urlsafe_base64(bytes)

    # scrypt$N$r$p$salt$hash (base64), the same format as sms-gateway.
    def hash_password(password)
      salt = SecureRandom.random_bytes(16)
      hash = OpenSSL::KDF.scrypt(password.to_s, salt: salt, N: SCRYPT[:n], r: SCRYPT[:r], p: SCRYPT[:p],
                                                length: SCRYPT[:length])
      "scrypt$#{SCRYPT[:n]}$#{SCRYPT[:r]}$#{SCRYPT[:p]}$#{[salt].pack('m0')}$#{[hash].pack('m0')}"
    end

    def verify_password(password, stored)
      alg, n, r, p, salt, hash = stored.to_s.split("$")
      return false unless alg == "scrypt" && salt && hash

      n = n.to_i
      r = r.to_i
      p = p.to_i
      return false unless n.between?(2, 1 << 20) && n.nobits?(n - 1) && r.between?(1, 32) && p.between?(1, 16)

      expected = hash.unpack1("m0")
      actual = OpenSSL::KDF.scrypt(password.to_s, salt: salt.unpack1("m0"), N: n, r: r, p: p, length: expected.bytesize)
      OpenSSL.fixed_length_secure_compare(actual, expected)
    rescue ArgumentError, OpenSSL::KDF::KDFError
      false
    end

    # Keeps sign-in timing uniform when the username does not exist.
    def dummy_hash
      @dummy_hash ||= hash_password(SecureRandom.hex(16))
    end

    def validate_password!(password)
      raise AppError.bad_request("Password must be at least 8 characters") if password.to_s.size < 8
      raise AppError.bad_request("Password is too long") if password.to_s.size > 200
    end
  end
end
