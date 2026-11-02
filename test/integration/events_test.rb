# frozen_string_literal: true

require "test_helper"
require "support/api_helpers"
require "puma"
require "socket"

# Server-Sent Events through a real Puma server: the hijacked stream, scopes, heartbeats of the hub,
# and that open streams do not hold request threads.
class EventsTest < ActiveSupport::TestCase
  include ApiHelpers

  setup do
    start_runtime
    Sim800c::ApiController.instance_variable_set(:@admin_checked, nil)
    @admin = login("admin", "admin-password")
    @server = Puma::Server.new(Rails.application, nil, min_threads: 1, max_threads: 1, log_writer: Puma::LogWriter.null)
    @server.add_tcp_listener("127.0.0.1", 0)
    @port = @server.connected_ports.first
    @server.run
    @sockets = []
  end

  teardown do
    @sockets.each { |s| s.close unless s.closed? }
    @server&.stop(true)
  end

  def open_stream(headers)
    socket = TCPSocket.new("127.0.0.1", @port)
    @sockets << socket
    socket.write("GET #{MOUNT}/api/v1/events HTTP/1.1\r\nHost: localhost\r\n" +
                 headers.map { |k, v| "#{k}: #{v}\r\n" }.join + "\r\n")
    socket
  end

  # Reads from the stream until the block accepts the text received so far.
  def read_until(socket, timeout = 3)
    buffer = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield(buffer)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      flunk "Timed out; stream so far:\n#{buffer}" if remaining <= 0
      next unless socket.wait_readable([remaining, 0.1].min)

      chunk = socket.read_nonblock(4096, exception: false)
      flunk "Stream closed; got:\n#{buffer}" if chunk.nil?
      buffer << chunk.force_encoding(Encoding::UTF_8) if chunk.is_a?(String)
    end
    buffer
  end

  def http_get(path, headers = {})
    Net::HTTP.start("127.0.0.1", @port, read_timeout: 3) do |http|
      http.get("#{MOUNT}#{path}", headers)
    end
  end

  test "streams events over SSE without holding a request thread" do
    stream = open_stream("Cookie" => @admin[:cookie])
    head = read_until(stream) { |b| b.include?("event: hello") }
    assert_match(%r{\AHTTP/1.1 200 OK\r\n}, head)
    assert_match(%r{content-type: text/event-stream; charset=utf-8}i, head)
    assert_match(/retry: 3000/, head)
    assert_match(/event: hello\ndata: \{"modem":\{"connection":"ready"/, head)

    # A second stream and an ordinary request still get through on a server with one thread.
    other = open_stream("Cookie" => @admin[:cookie])
    read_until(other) { |b| b.include?("event: hello") }
    assert_equal "200", http_get("/api/v1/modem", "Cookie" => @admin[:cookie]).code
    assert_equal 2, Sim800c::Web::EventHub.instance.size

    on_runtime { simulator.inject_sms("+639175558888", "streamed") }
    text = read_until(stream) { |b| b.match?(/event: sms.received\ndata: .*streamed/) }
    assert_match(/event: sms.received\ndata: \{"id":\d+,"direction":"inbound","phone":"\+639175558888"/, text)

    stream.close
    other.close
    wait_for(3, "clients dropped") { Sim800c::Web::EventHub.instance.size.zero? }
  end

  test "sends only the events the principal's scopes allow" do
    key = create_key(@admin, ["calls:read"])
    stream = open_stream("X-API-Key" => key)
    hello = read_until(stream) { |b| b.include?("event: hello") }
    assert_match(/event: hello\ndata: \{"modem":null,"call":null\}/, hello)
    on_runtime { simulator.inject_sms("+639175558888", "hidden") }
    wait_for(3, "received") { Sim800c::SmsMessage.exists?(body: "hidden") }
    on_runtime { simulator.inject_call("+639175550001") }
    text = read_until(stream) { |b| b.include?("event: call.incoming") }
    refute_match(/sms\.received|log\.entry|modem\.status/, text)
  end

  test "rejects unauthenticated streams" do
    response = http_get("/api/v1/events")
    assert_equal "401", response.code
    assert_equal "unauthorized", JSON.parse(response.body).dig("error", "code")
  end

  test "reports the runtime going away and coming back" do
    stream = open_stream("Cookie" => @admin[:cookie])
    read_until(stream) { |b| b.include?("event: hello") }
    stop_runtime
    read_until(stream, 5) { |b| b.include?("Gateway runtime is not running") }
    start_runtime
    read_until(stream, 10) { |b| b.match?(/"connection":"ready"/) }
  end

  test "does not report the runtime offline when the last stream closes and a new one opens" do
    first = open_stream("Cookie" => @admin[:cookie])
    read_until(first) { |b| b.include?("event: hello") }
    wait_for(3, "hub follows the runtime") { Sim800c::Web::EventHub.instance.warm? }
    first.close
    wait_for(3, "hub idle") { Sim800c::Web::EventHub.instance.size.zero? && !Sim800c::Web::EventHub.instance.warm? }
    second = open_stream("Cookie" => @admin[:cookie])
    hello = read_until(second) { |b| b.include?("event: hello") }
    assert_match(/"connection":"ready"/, hello)
    on_runtime { simulator.inject_sms("+639175558888", "after reconnect") }
    text = read_until(second) { |b| b.include?("after reconnect") }
    refute_match(/not running/, text)
  end

  test "falls back to a streaming body on servers without hijack" do
    env = Rack::MockRequest.env_for("#{MOUNT}/api/v1/events", "HTTP_COOKIE" => @admin[:cookie], "REMOTE_ADDR" => "127.0.0.1")
    status, headers, body = Rails.application.call(env)
    assert_equal 200, status
    assert_equal "text/event-stream; charset=utf-8", headers["content-type"]
    chunks = Queue.new
    reader = Thread.new { body.each { |chunk| chunks << chunk } }
    assert_match(/event: hello/, chunks.pop(timeout: 3))
    on_runtime { simulator.inject_sms("+639175558888", "fallback") }
    frame = wait_for(3, "sms.received") do
      chunk = chunks.pop(timeout: 0.2)
      chunk if chunk&.include?("event: sms.received")
    end
    assert_match(/fallback/, frame)
    body.close
    reader.join(2)
    refute reader.alive?
  end
end
