# frozen_string_literal: true

require "set"

module Sim800c
  module AT
    # kind: :error, :cme, :cms, :timeout or :disconnected
    class CommandError < Sim800c::Error
      attr_reader :kind, :command, :code

      def initialize(kind, command, message, code = nil)
        super(message)
        @kind = kind
        @command = command
        @code = code
      end
    end

    ParsedError = Data.define(:kind, :code, :message)

    # 3GPP TS 27.007 mobile equipment errors (subset relevant to SIM800).
    CME_ERRORS = {
      0 => "Phone failure",
      3 => "Operation not allowed",
      4 => "Operation not supported",
      5 => "PH-SIM PIN required",
      10 => "SIM not inserted",
      11 => "SIM PIN required",
      12 => "SIM PUK required",
      13 => "SIM failure",
      14 => "SIM busy",
      15 => "SIM wrong",
      16 => "Incorrect password",
      17 => "SIM PIN2 required",
      18 => "SIM PUK2 required",
      20 => "Memory full",
      21 => "Invalid index",
      22 => "Not found",
      23 => "Memory failure",
      24 => "Text string too long",
      25 => "Invalid characters in text string",
      26 => "Dial string too long",
      27 => "Invalid characters in dial string",
      30 => "No network service",
      31 => "Network timeout",
      32 => "Network not allowed — emergency calls only",
      100 => "Unknown error"
    }.freeze

    # 3GPP TS 27.005 / 24.011 message service errors. Codes < 128 come from the network.
    CMS_ERRORS = {
      1 => "Unassigned (unallocated) number",
      8 => "Operator determined barring",
      10 => "Call barred",
      21 => "Short message transfer rejected",
      27 => "Destination out of service",
      28 => "Unidentified subscriber",
      29 => "Facility rejected",
      30 => "Unknown subscriber",
      38 => "Network out of order",
      41 => "Temporary network failure",
      42 => "Network congestion",
      47 => "Network resources unavailable",
      50 => "Requested facility not subscribed",
      69 => "Requested facility not implemented",
      81 => "Invalid short message reference",
      95 => "Invalid message",
      96 => "Invalid mandatory information",
      97 => "Message type non-existent",
      98 => "Message not compatible with protocol state",
      111 => "Protocol error",
      127 => "Interworking error",
      300 => "ME failure",
      301 => "SMS service of ME reserved",
      302 => "Operation not allowed",
      303 => "Operation not supported",
      304 => "Invalid PDU mode parameter",
      305 => "Invalid text mode parameter",
      310 => "SIM not inserted",
      311 => "SIM PIN required",
      312 => "PH-SIM PIN required",
      313 => "SIM failure",
      314 => "SIM busy",
      315 => "SIM wrong",
      316 => "SIM PUK required",
      320 => "Memory failure",
      321 => "Invalid memory index",
      322 => "SIM memory full",
      330 => "SMSC address unknown",
      331 => "No network service",
      332 => "Network timeout",
      340 => "No +CNMA acknowledgement expected",
      500 => "Unknown error"
    }.freeze

    # SMS errors that will not succeed on retry (bad number, barring, malformed PDU...).
    PERMANENT_CMS = Set[1, 8, 10, 21, 29, 30, 50, 69, 96, 97, 98, 99, 303, 304, 305].freeze

    module_function

    # ParsedError for ERROR / +CME ERROR / +CMS ERROR lines, else nil.
    def parse_error_line(line)
      return ParsedError.new(kind: :error, code: nil, message: "Command rejected by modem (ERROR)") if line == "ERROR"

      m = /\A\+(CME|CMS) ERROR:\s*(.+)\z/.match(line) or return nil
      kind = m[1] == "CME" ? :cme : :cms
      raw = m[2].strip
      if raw.match?(/\A\d+\z/)
        code = raw.to_i
        table = kind == :cme ? CME_ERRORS : CMS_ERRORS
        return ParsedError.new(kind: kind, code: code, message: "#{table[code] || 'Modem error'} (#{kind.to_s.upcase} #{code})")
      end
      ParsedError.new(kind: kind, code: nil, message: raw)
    end

    def retryable_sms_error?(error)
      return true unless error.is_a?(CommandError)
      return !PERMANENT_CMS.include?(error.code) if error.kind == :cms && error.code

      true
    end
  end
end
