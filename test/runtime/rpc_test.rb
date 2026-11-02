# frozen_string_literal: true

require "test_helper"

# Web process <-> runtime over the RPC socket.
class RpcTest < ActiveSupport::TestCase
  test "answers status and live operations through the gateway" do
    start_runtime
    snapshot = Sim800c::Gateway.snapshot
    assert_equal "ready", snapshot.dig("modem", "connection")
    assert_equal true, snapshot["canOperate"]
    assert_equal true, snapshot["simulator"]
    session = Sim800c::Gateway.request("ussd.send", { code: "*123#", actor: { source: "api" } })
    assert_equal "completed", session["status"]
    assert_equal({ "modem" => "ready" }, Sim800c::Gateway.request("health"))
  end

  test "carries API errors back with their status and code" do
    start_runtime
    error = assert_raises(Sim800c::AppError) { Sim800c::Gateway.request("calls.hangup") }
    assert_equal [409, "conflict", "There is no active call"], [error.status, error.code, error.message]
    error = assert_raises(Sim800c::AppError) { Sim800c::Gateway.request("calls.dial", { number: "*123#" }) }
    assert_equal 400, error.status
    error = assert_raises(Sim800c::AppError) { Sim800c::Gateway.request("nope") }
    assert_match(/Unknown RPC operation/, error.message)
  end

  test "refuses a wrong token" do
    start_runtime
    client = Sim800c::RPC::Client.new(url: Sim800c::RPC.url, token: "wrong")
    error = assert_raises(Sim800c::AppError) { client.request("status") }
    assert_equal 401, error.status
  end

  test "reports a runtime that is not running as 503 and an offline status" do
    configure_for_tests
    error = assert_raises(Sim800c::AppError) { Sim800c::Gateway.request("calls.active") }
    assert_equal [503, "modem_unavailable"], [error.status, error.code]
    assert_match(/runtime is not running/, error.message)
    snapshot = Sim800c::Gateway.snapshot
    assert_equal "disconnected", snapshot.dig("modem", "connection")
    assert_equal false, snapshot["canOperate"]
    assert_nil Sim800c::Gateway.notify(kick: true)
  end

  test "streams events, starting with the current modem status" do
    start_runtime
    client = Sim800c::Gateway.client
    events = Queue.new
    thread = Thread.new { client.subscribe { |name, data| events << [name, data] } rescue nil } # rubocop:disable Style/RescueModifier
    name, data = events.pop(timeout: 2)
    assert_equal "modem.status", name
    assert_equal "ready", data["connection"]
    on_runtime { simulator.inject_sms("+639175558888", "streamed") }
    received = wait_for(3, "sms.received") do
      item = events.pop(timeout: 0.1)
      item if item && item[0] == "sms.received"
    end
    assert_equal "streamed", received[1]["body"]
    client.unsubscribe
    thread.join(2)
    refute thread.alive?
    wait_for(2, "listener removed") { on_runtime { @runtime.bus.listener_count("sms.received") }.zero? }
  end

  test "notify re-broadcasts changes made by web processes and wakes the worker" do
    start_runtime
    events = record_events("sms.updated", "sms.status", "sms.deleted", "log.entry")
    records, = Sim800c::SmsMessage.enqueue(to: ["+639171234567"], text: "via notify", source: "api")
    entry = Sim800c::EventLogEntry.record!(:info, "sms", "from the web")
    Sim800c::Gateway.notify(sms_updated: records.map(&:id), log: [entry.id], kick: true)
    wait_for(4, "delivered") { sms(records.first.id).status == "delivered" }
    Sim800c::Gateway.notify(sms_deleted: [records.first.id])
    wait_for(2, "deleted event") { drain(events).tap { |e| @seen = (@seen || []) + e }.empty? && @seen.any? { |n, _| n == "sms.deleted" } }
    names = @seen.map(&:first)
    assert_includes names, "log.entry"
    assert_equal "queued", @seen.find { |n, _| n == "sms.updated" }[1][:status]
    assert_equal({ ids: [records.first.id] }, @seen.find { |n, _| n == "sms.deleted" }[1])
  end

  test "allows a single runtime per lock file and per socket" do
    start_runtime
    error = assert_raises(Sim800c::Error) { Sim800c::Runtime.new.start }
    assert_match(/already running/, error.message)
    Sim800c.config.lock_file = nil
    error = assert_raises(Sim800c::Error) { Sim800c::Runtime.new.start }
    assert_match(/listening on/, error.message)
  end

  test "replaces a stale socket file left by a crashed runtime" do
    configure_for_tests
    path = Sim800c::RPC.url.delete_prefix("unix://")
    FileUtils.mkdir_p(File.dirname(path))
    UNIXServer.new(path).close # leaves the file behind, nobody listening
    assert File.socket?(path)
    @runtime = Sim800c::Runtime.new.start
    assert_equal({ "modem" => "connecting" }.keys, Sim800c::Gateway.request("health").keys)
    assert_equal "600", format("%o", File.stat(path).mode & 0o777)
  end

  test "works over TCP" do
    configure_for_tests("rpc.url" => "tcp://127.0.0.1:0")
    @runtime = Sim800c::Runtime.new.start
    port = @runtime.rpc_server.port
    Sim800c.config.rpc.url = "tcp://127.0.0.1:#{port}"
    assert wait_for(5, "ready") { Sim800c::Gateway.snapshot["canOperate"] }
    assert_match(/\Atcp:/, @runtime.rpc_server.description)
  end
end
