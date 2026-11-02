# frozen_string_literal: true

# Transport whose modem side is scripted by the test. Lives on the reactor thread.
class FakeTransport < Sim800c::Transport::Base
  attr_reader :writes
  attr_accessor :on_write, :opened

  def initialize(reactor)
    super
    @writes = []
    @opened = true
    @on_write = ->(_data) {}
  end

  def description = "fake"
  def open? = @opened

  def open
    @opened = true
    Sim800c::Promise.resolved
  end

  def close
    @opened = false
    emit(:close, nil)
    Sim800c::Promise.resolved
  end

  def write(data)
    s = data.to_s
    @writes << s
    @on_write.call(s)
    Sim800c::Promise.resolved
  end

  # Data arriving from the modem.
  def feed(string)
    emit(:data, string.b)
  end
end
