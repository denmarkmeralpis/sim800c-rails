# frozen_string_literal: true

module Sim800c
  class Runtime
    # Writes user-visible log entries (persisted, streamed as log.entry) and mirrors them to the logger.
    class EventLog
      def initialize(bus:, logger:)
        @bus = bus
        @logger = logger
      end

      def info(category, message, data = nil) = write(:info, category, message, data)
      def warn(category, message, data = nil) = write(:warn, category, message, data)
      def error(category, message, data = nil) = write(:error, category, message, data)

      private

      def write(level, category, message, data)
        @logger.public_send(level, "[sim800c] [#{category}] #{message}")
        entry = EventLogEntry.record!(level, category, message, data)
        @bus.emit("log.entry", entry.as_api)
        nil
      rescue StandardError => e
        @logger.error("[sim800c] Failed to persist event log entry: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
