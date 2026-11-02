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

  test "streams events, starting with a snapshot of the modem and the call" do
    start_runtime
    client = Sim800c::Gateway.client
    events = Queue.new
    thread = Thread.new { client.subscribe { |name, data| events << [name, data] } rescue nil } # rubocop:disable Style/RescueModifier
    name, data = events.pop(timeout: 2)
    assert_equal "snapshot", name
    assert_equal "ready", data.dig("modem", "connection")
    assert_nil data["call"]
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

class RpcStopTest < ActiveSupport::TestCase
  test "answers clients still waiting in the listen queue when stopping" do
    configure_for_tests
    server = Sim800c::RPC::Server.new(url: Sim800c::RPC.url, token: "t", handler: nil).start
    # Stop the acceptor the way #stop does, so the next client stays queued, then stop.
    server.instance_variable_set(:@stopping, true)
    server.instance_variable_get(:@wake_writer).write(".")
    server.instance_variable_get(:@accept_thread).join(2)
    client = UNIXSocket.new(Sim800c::RPC.url.delete_prefix("unix://"))
    client.write("{}\n")
    server.stop
    client.timeout = 2
    reply = JSON.parse(client.gets)
    assert_equal [503, "modem_unavailable"], [reply.dig("error", "status"), reply.dig("error", "code")]
  ensure
    client&.close
  end
end

class RpcUrlTest < ActiveSupport::TestCase
  test "defaults to tmp/sockets, or a short per-app path when that is too long for a Unix socket" do
    configure_for_tests("rpc.url" => nil)
    assert_equal "unix://#{Rails.root.join('tmp/sockets/sim800c.sock')}", Sim800c::RPC.url
    long_root = Pathname.new("/srv/#{'deeply/nested/' * 8}app")
    path = Sim800c::RPC.default_socket_path(long_root)
    assert path.start_with?("#{Dir.tmpdir}/sim800c-#{Process.euid}/")
    assert_operator path.bytesize, :<=, Sim800c::RPC::MAX_SOCKET_PATH
    assert_equal path, Sim800c::RPC.default_socket_path(long_root.to_s) # every process of the app agrees
    refute_equal path, Sim800c::RPC.default_socket_path("/srv/#{'deeply/nested/' * 8}other")
  end

  test "keeps the fallback socket in a private directory" do
    path = Sim800c::RPC.default_socket_path("/srv/#{'deeply/nested/' * 8}app")
    dir = File.dirname(path)
    FileUtils.rm_rf(dir)
    Sim800c::RPC.secure_socket_dir!(path)
    assert_equal "700", format("%o", File.stat(dir).mode & 0o777)
    File.chmod(0o755, dir)
    error = assert_raises(Sim800c::ConfigError) { Sim800c::RPC.secure_socket_dir!(path) }
    assert_match(/mode 0700/, error.message)
    client = Sim800c::RPC::Client.new(url: "unix://#{path}", token: "t")
    assert_raises(Sim800c::RPC::Unavailable) { client.request("health") } # never sends the token there
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "parses unix and tcp urls" do
    assert_equal [:unix, "/run/sim800c.sock"], Sim800c::RPC.parse_url("unix:///run/sim800c.sock")
    assert_equal [:unix, "/run/sim800c.sock"], Sim800c::RPC.parse_url("/run/sim800c.sock")
    assert_equal [:tcp, "runtime", 7071], Sim800c::RPC.parse_url("tcp://runtime:7071")
    assert_equal [:tcp, "::1", 7071], Sim800c::RPC.parse_url("tcp://[::1]:7071")
  end
end
