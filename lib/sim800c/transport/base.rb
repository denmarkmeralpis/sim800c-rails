# frozen_string_literal: true

module Sim800c
  module Transport
    # Byte-level link to the modem. Implemented by the serial port, the TCP bridge client and the
    # simulator. All methods are called on the reactor thread and return Promises; events are
    # emitted on the reactor thread:
    #
    #   :data  (binary String)
    #   :close (error or nil) — error is set for unexpected disconnects (e.g. USB unplugged)
    #   :error (error)
    class Base
      include Emitter

      attr_reader :reactor

      def initialize(reactor)
        @reactor = reactor
      end

      def description = raise(NotImplementedError)
      def open? = raise(NotImplementedError)
      def open = raise(NotImplementedError)
      def write(_data) = raise(NotImplementedError)
      def close = raise(NotImplementedError)
    end
  end
end
