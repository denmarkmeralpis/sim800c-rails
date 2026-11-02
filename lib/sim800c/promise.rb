# frozen_string_literal: true

module Sim800c
  # A one-shot result, settled once with a value or an error. Not thread-safe: promises are created,
  # settled and observed on the reactor thread (other threads go through Reactor#post).
  class Promise
    def self.resolved(value = nil)
      new.tap { |p| p.resolve(value) }
    end

    def self.rejected(error)
      new.tap { |p| p.reject(error) }
    end

    def initialize
      @state = :pending
      @value = nil
      @callbacks = []
    end

    def pending? = @state == :pending
    def fulfilled? = @state == :fulfilled
    def rejected? = @state == :rejected
    def settled? = @state != :pending

    # The error of a rejected promise, or nil.
    def reason = rejected? ? @value : nil

    def resolve(value = nil) = settle(:fulfilled, value)

    def reject(error) = settle(:rejected, error)

    # The value, or raises the error. Only valid once settled.
    def value!
      raise Error, "promise is still pending" if pending?
      raise @value if rejected?

      @value
    end

    # Runs the block with this promise once it is settled (immediately if it already is).
    def on_settle(&block)
      if settled?
        block.call(self)
      else
        @callbacks << block
      end
      self
    end

    private

    def settle(state, value)
      return false unless pending?

      @state = state
      @value = value
      callbacks = @callbacks
      @callbacks = nil
      callbacks.each { |cb| cb.call(self) }
      true
    end
  end
end
