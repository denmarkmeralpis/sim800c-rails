# frozen_string_literal: true

module Sim800c
  class Runtime
    # Runs blocks one after another on the reactor (each may await), in the order they were queued.
    class SerialQueue
      def initialize(reactor, &on_error)
        @reactor = reactor
        @on_error = on_error
        @tail = Promise.resolved
      end

      # Queues the block; returns a Promise that settles (never rejects) once it has run.
      def enqueue(&task)
        previous = @tail
        @tail = @reactor.task do
          @reactor.await(previous)
          begin
            task.call
          rescue StandardError => e
            @on_error&.call(e)
          end
          nil
        end
      end

      # Waits (inside a task) until everything queued so far has run.
      def drain
        @reactor.await(@tail)
      end
    end
  end
end
