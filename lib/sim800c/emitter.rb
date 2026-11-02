# frozen_string_literal: true

module Sim800c
  # Minimal synchronous event emitter (like Node's EventEmitter).
  #
  # Listeners run on the emitting thread, in registration order. A listener that raises is logged
  # and does not stop the others. Registration is thread-safe: listener lists are copy-on-write,
  # so `emit` iterates a stable snapshot without locking.
  module Emitter
    def on(event, callable = nil, &block)
      handler = callable || block
      raise ArgumentError, "listener required" unless handler

      emitter_lock.synchronize { emitter_listeners[event] = [*emitter_listeners[event], handler] }
      handler
    end

    def once(event, &block)
      wrapper = nil
      wrapper = lambda do |*args|
        off(event, wrapper)
        block.call(*args)
      end
      on(event, wrapper)
    end

    def off(event, handler)
      emitter_lock.synchronize do
        list = emitter_listeners[event] or return
        idx = list.index { |h| h.equal?(handler) } or return
        updated = list.dup
        updated.delete_at(idx)
        emitter_listeners[event] = updated
      end
      handler
    end

    def remove_all_listeners(event = nil)
      emitter_lock.synchronize { event ? emitter_listeners.delete(event) : emitter_listeners.clear }
      self
    end

    def listener_count(event)
      emitter_listeners[event]&.size || 0
    end

    def emit(event, *args)
      list = emitter_listeners[event]
      return false if list.nil? || list.empty?

      list.each do |handler|
        handler.call(*args)
      rescue StandardError => e
        Sim800c.logger.error("[sim800c] #{self.class.name} #{event} listener failed: #{e.class}: #{e.message}\n" \
                             "#{e.backtrace&.first(8)&.join("\n")}")
      end
      true
    end

    private

    def emitter_listeners
      @emitter_listeners ||= {}
    end

    def emitter_lock
      @emitter_lock ||= Mutex.new
    end
  end
end
