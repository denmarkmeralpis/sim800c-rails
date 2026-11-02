# frozen_string_literal: true

# Helper for tests of the modem stack that do not need Rails.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "sim800c/core"

Sim800c.logger = Logger.new($stderr, level: ENV.fetch("SIM800C_TEST_LOG", "fatal"))

module Sim800cTestHelpers
  # Waits until the block returns truthy, polling every 20 ms (like sms-gateway's waitFor).
  def wait_for(timeout = 5, what = "condition")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (result = yield)
      raise Minitest::Assertion, "Timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
    result
  end
end

class Minitest::Test
  include Sim800cTestHelpers
end
