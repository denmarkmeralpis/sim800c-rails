# frozen_string_literal: true

module Sim800c
  module Transport
    # Shared plumbing for transports backed by a real IO (serial device, TCP socket): a reader
    # thread that posts received bytes to the reactor, and a writer thread so a stalled device can
    # never block the reactor. Including classes implement #connect_io (runs on a helper thread and
    # returns the open IO) and #description, and may override #closed_error.
    module IoLink
      def open? = !@io.nil?

      def open
        return Promise.resolved if open?

        reactor.task do
          io = reactor.await(reactor.defer { connect_io })
          attach(io)
          nil
        end
      end

      def write(data)
        return Promise.rejected(Error.new(not_open_message)) unless open?

        promise = Promise.new
        @write_queue << [data.to_s.b, promise]
        promise
      rescue ClosedQueueError
        Promise.rejected(Error.new(not_open_message))
      end

      def close
        io = @io
        return Promise.resolved unless io

        @closing = true
        promise = Promise.new
        (@close_waiters ||= []) << promise
        @write_queue&.close
        before_close(io)
        begin
          io.close
        rescue IOError, SystemCallError
          nil
        end
        promise
      end

      private

      def not_open_message = "#{description} is not open"

      def before_close(_io); end

      # Error reported with :close when the far end went away (nil when we closed it ourselves).
      def closed_error(error)
        error.is_a?(EOFError) ? Error.new("Device disconnected") : error
      end

      def attach(io)
        @io = io
        @closing = false
        queue = @write_queue = Thread::Queue.new
        start_writer(io, queue)
        start_reader(io)
      end

      def start_reader(io)
        Thread.new do
          Thread.current.name = "sim800c-#{self.class.name.split('::').last.downcase}-reader"
          Thread.current.report_on_exception = false
          loop do
            chunk = io.readpartial(4096)
            reactor.post { emit(:data, chunk) if @io.equal?(io) }
          end
        rescue EOFError, IOError, SystemCallError => e
          reactor.post { on_io_closed(io, e) }
        end
      end

      def start_writer(io, queue)
        Thread.new do
          Thread.current.name = "sim800c-#{self.class.name.split('::').last.downcase}-writer"
          Thread.current.report_on_exception = false
          while (item = queue.pop)
            data, promise = item
            begin
              io.write(data)
              reactor.post { promise.resolve }
            rescue IOError, SystemCallError => e
              reactor.post { promise.reject(e) }
            end
          end
        end
      end

      def on_io_closed(io, error)
        return unless @io.equal?(io)

        @io = nil
        @write_queue&.close
        begin
          io.close
        rescue IOError, SystemCallError
          nil
        end
        if @closing
          emit(:close, nil)
        else
          reason = closed_error(error)
          emit(:error, reason) if error.is_a?(SystemCallError)
          emit(:close, reason)
        end
        waiters = @close_waiters || []
        @close_waiters = []
        waiters.each(&:resolve)
      end
    end
  end
end
