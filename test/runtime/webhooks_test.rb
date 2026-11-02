# frozen_string_literal: true

require "test_helper"
require "support/http_receiver"

# Webhook delivery, against a local HTTP server standing in for the receiving integration.
class WebhooksTest < ActiveSupport::TestCase
  teardown { @receiver&.close }

  test "delivers a signed ussd.ended once the session finishes" do
    @receiver = HttpReceiver.new
    start_runtime(rpc: false, "webhook.url" => @receiver.url, "webhook.secret" => "hook-secret",
                              "webhook.events" => ["ussd.ended"])
    menu = on_runtime { @runtime.ussd.send_code("*143#", { source: "api" }) }
    assert_equal "open", menu[:status]
    done = on_runtime { @runtime.ussd.reply("2") }
    request = @receiver.requests.pop(timeout: 3)
    refute_nil request, "webhook delivery"
    assert_nil @receiver.requests.pop(timeout: 0.2), "no second delivery for the same session"

    assert_equal "POST", request.method
    assert_equal "ussd.ended", request.headers["x-webhook-event"]
    assert_equal "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', 'hook-secret', request.body)}",
                 request.headers["x-webhook-signature"]
    payload = JSON.parse(request.body)
    assert_equal "ussd.ended", payload["event"]
    assert_equal JSON.parse(JSON.generate(done)), payload["data"]
    assert_equal menu[:id], payload["data"]["id"]
  end

  test "delivers sms.received and sms.status, unsigned without a secret" do
    @receiver = HttpReceiver.new
    start_runtime(rpc: false, "webhook.url" => @receiver.url)
    on_runtime { simulator.inject_sms("+639175551234", "Hi!") }
    request = @receiver.requests.pop(timeout: 3)
    assert_equal "sms.received", JSON.parse(request.body)["event"]
    assert_nil request.headers["x-webhook-signature"]
    assert_equal "Hi!", JSON.parse(request.body).dig("data", "body")

    records, = Sim800c::SmsMessage.enqueue(to: ["+639171234567"], text: "status please", source: "api")
    on_runtime { @runtime.sms.kick }
    statuses = Array.new(2) { JSON.parse(@receiver.requests.pop(timeout: 4).body) }
    assert_equal [%w[sms.status sent], %w[sms.status delivered]], statuses.map { |p| [p["event"], p.dig("data", "status")] }
    assert_equal records.first.id, statuses.last.dig("data", "id")
  end

  test "retries failed deliveries and stops on a client error" do
    @receiver = HttpReceiver.new(status: 500)
    start_runtime(rpc: false, "webhook.url" => @receiver.url, "webhook.events" => ["sms.received"])
    stub_const_retry_delays([0.05, 0.05, 0.05]) do
      on_runtime { simulator.inject_sms("+639175551234", "retry me") }
      4.times { refute_nil @receiver.requests.pop(timeout: 3), "attempt" }
      assert_nil @receiver.requests.pop(timeout: 0.3), "gives up after 3 retries"
    end
  end

  def stub_const_retry_delays(delays)
    klass = Sim800c::Runtime::Webhooks
    original = klass::RETRY_DELAYS
    klass.send(:remove_const, :RETRY_DELAYS)
    klass.const_set(:RETRY_DELAYS, delays)
    yield
  ensure
    klass.send(:remove_const, :RETRY_DELAYS)
    klass.const_set(:RETRY_DELAYS, original)
  end
end
