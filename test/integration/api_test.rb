# frozen_string_literal: true

require "test_helper"
require "support/api_helpers"

# HTTP API: authentication, CSRF, API key scopes, validation and the main endpoints, through the
# full stack (Rails app -> engine -> RPC -> runtime -> simulator).
class ApiTest < ActiveSupport::TestCase
  include ApiHelpers

  setup do
    start_runtime
    Sim800c::ApiController.instance_variable_set(:@admin_checked, nil)
    @admin = login("admin", "admin-password")
  end

  def ids(res) = res.body["data"].map { |m| m["id"] }

  # -- authentication ------------------------------------------------------------------------------

  test "rejects bad credentials and unauthenticated requests" do
    assert_equal 401, req("/api/auth/login", body: { username: "admin", password: "nope" }).status
    assert_equal 401, req("/api/v1/sms").status
    assert_equal 401, req("/api/v1/sms", key: "smsgw_not-a-real-key").status
    assert_equal "unauthorized", req("/api/v1/sms").body.dig("error", "code")
  end

  test "sets an HttpOnly SameSite session cookie scoped to the mount path and returns the CSRF token" do
    res = req("/api/auth/login", body: { username: "admin", password: "admin-password" })
    cookie = res.headers["set-cookie"]
    assert_match(/sim800c_session=/, cookie)
    assert_match(/httponly/i, cookie)
    assert_match(/samesite=strict/i, cookie)
    assert_match(%r{path=/sms-gateway}i, cookie)
    assert_equal %w[user csrfToken scopes expiresAt], res.body.keys
    me = req("/api/auth/me", session: @admin)
    assert_equal "admin", me.body.dig("user", "username")
    assert_includes me.body["scopes"], "admin"
  end

  test "requires the CSRF token for cookie-authenticated writes" do
    res = req("/api/v1/sms", body: { to: "+639171234567", message: "hi" }, session: @admin, csrf: false)
    assert_equal 403, res.status
    assert_equal "csrf_failed", res.body.dig("error", "code")
  end

  test "logs out and invalidates the session" do
    s = login("admin", "admin-password")
    res = req("/api/auth/logout", method: :post, session: s)
    assert_equal 204, res.status
    assert_match(/max-age=0/i, res.headers["set-cookie"])
    assert_equal 401, req("/api/auth/me", session: s).status
  end

  test "rate limits failed sign-ins" do
    Sim800c.config.auth.login_rate_limit = 3
    from = { "X-Forwarded-For" => "203.0.113.7" }
    3.times { assert_equal 401, req("/api/auth/login", body: { username: "admin", password: "bad" }, headers: from).status }
    res = req("/api/auth/login", body: { username: "admin", password: "admin-password" }, headers: from)
    assert_equal 429, res.status
    assert_match(/Too many failed sign-in attempts/, res.body.dig("error", "message"))
    # Counted per client address: others can still sign in.
    assert_equal 200, req("/api/auth/login", body: { username: "admin", password: "admin-password" }).status
  ensure
    Sim800c::Web::RateLimiter.store.clear
  end

  # -- API keys and roles --------------------------------------------------------------------------

  test "enforces API key scopes and revocation" do
    key = create_key(@admin, ["sms:send"])
    sent = req("/api/v1/sms", body: { to: "+639171234567", message: "via key" }, key: key)
    assert_equal 202, sent.status
    assert_equal "api", sent.body["data"][0]["source"]
    assert_equal "120", sent.headers["ratelimit-policy"][/q=(\d+)/, 1]

    read = req("/api/v1/sms", key: key)
    assert_equal 403, read.status
    assert_match(/sms:read/, read.body.dig("error", "message"))
    assert_equal 403, req("/api/v1/calls", body: { number: "+639171234567" }, key: key).status
    assert_equal 403, req("/api/v1/admin/keys", key: key).status

    list = req("/api/v1/admin/keys", session: @admin)
    id = list.body["data"].find { |k| key.start_with?(k["prefix"]) }["id"]
    assert_equal 200, req("/api/v1/admin/keys/#{id}", method: :delete, session: @admin).status
    assert_equal 401, req("/api/v1/sms", body: { to: "+639171234567", message: "x" }, key: key).status
  end

  test "accepts Authorization: Bearer and does not allow the admin scope on keys" do
    key = create_key(@admin, ["modem:read"])
    assert_equal 200, req("/api/v1/modem", headers: { "Authorization" => "Bearer #{key}" }).status
    assert_equal 400, req("/api/v1/admin/keys", body: { name: "x", scopes: ["admin"] }, session: @admin).status
  end

  test "rate limits API keys" do
    Sim800c.config.auth.api_rate_limit_per_min = 2
    key = create_key(@admin, ["modem:read"])
    2.times { assert_equal 200, req("/api/v1/modem/events", key: key).status }
    res = req("/api/v1/modem/events", key: key)
    assert_equal [429, "rate_limited"], [res.status, res.body.dig("error", "code")]
    assert_equal 200, req("/api/v1/modem/events", session: @admin).status # sessions are not limited
  ensure
    Sim800c::Web::RateLimiter.store.clear
  end

  test "limits viewers to read-only access" do
    created = req("/api/v1/admin/users", body: { username: "viewer1", password: "viewer-pass", role: "viewer" }, session: @admin)
    assert_equal 201, created.status
    viewer = login("viewer1", "viewer-pass")
    assert_equal 200, req("/api/v1/sms", session: viewer).status
    assert_equal 403, req("/api/v1/sms", body: { to: "+639171234567", message: "x" }, session: viewer).status
    assert_equal 403, req("/api/v1/modem/reconnect", method: :post, session: viewer).status
  end

  test "protects the last admin account and manages users" do
    users = req("/api/v1/admin/users", session: @admin)
    me = users.body["data"].find { |u| u["username"] == "admin" }
    assert_equal 400, req("/api/v1/admin/users/#{me['id']}", method: :delete, session: @admin).status
    assert_equal %w[admin operator viewer], users.body["roles"].keys

    op = req("/api/v1/admin/users", body: { username: "Op1", password: "operator-pass", role: "operator" }, session: @admin)
    assert_equal 409, req("/api/v1/admin/users", body: { username: "op1", password: "operator-pass", role: "viewer" }, session: @admin).status
    op_session = login("OP1", "operator-pass")
    patched = req("/api/v1/admin/users/#{op.body['data']['id']}", method: :patch, body: { role: "viewer" }, session: @admin)
    assert_equal "viewer", patched.body.dig("data", "role")
    assert_equal 401, req("/api/auth/me", session: op_session).status # role change signs out
    assert_equal 400, req("/api/v1/admin/users/#{op.body['data']['id']}", method: :patch, body: {}, session: @admin).status
    assert_equal 204, req("/api/v1/admin/users/#{op.body['data']['id']}", method: :delete, session: @admin).status
  end

  test "changes the password and signs out other sessions" do
    other = login("admin", "admin-password")
    bad = req("/api/auth/password", body: { currentPassword: "wrong", newPassword: "new-password-1" }, session: @admin)
    assert_equal 400, bad.status
    assert_equal 204, req("/api/auth/password", body: { currentPassword: "admin-password", newPassword: "new-password-1" }, session: @admin).status
    assert_equal 200, req("/api/auth/me", session: @admin).status
    assert_equal 401, req("/api/auth/me", session: other).status
    login("admin", "new-password-1")
  end

  # -- SMS endpoints -------------------------------------------------------------------------------

  test "validates SMS input" do
    empty = req("/api/v1/sms", body: { to: [], message: "x" }, session: @admin)
    assert_equal 400, empty.status
    assert_equal "validation_error", empty.body.dig("error", "code")
    assert_equal "to: At least one recipient is required", empty.body.dig("error", "message")
    assert_equal [{ "path" => "to", "message" => "At least one recipient is required" }], empty.body.dig("error", "details")
    bad_number = req("/api/v1/sms", body: { to: "call me", message: "x" }, session: @admin)
    assert_equal 400, bad_number.status
    assert_match(/Invalid phone number/, bad_number.body.dig("error", "message"))
    bad_json = req("/api/v1/sms", raw: "{nope", session: @admin)
    assert_equal [400, "invalid_json"], [bad_json.status, bad_json.body.dig("error", "code")]
    too_big = req("/api/v1/sms", raw: JSON.generate({ to: "+639171234567", message: "x" * 120_000 }), session: @admin)
    assert_equal [413, "payload_too_large"], [too_big.status, too_big.body.dig("error", "code")]
    missing = req("/api/v1/sms", body: { to: "+639171234567" }, session: @admin)
    assert_equal "message", missing.body.dig("error", "details", 0, "path")
  end

  test "queues to several recipients and reports status" do
    res = req("/api/v1/sms", body: { to: "+639171234567, 09181234567", message: "Hello both" }, session: @admin)
    assert_equal 202, res.status
    assert_equal 2, res.body["data"].size
    id = res.body["data"][0]["id"]
    wait_for(4, "delivered") { sms(id).status == "delivered" }
    one = req("/api/v1/sms/#{id}", session: @admin)
    assert_equal "delivered", one.body.dig("data", "status")
    list = req("/api/v1/sms?direction=outbound&limit=1", session: @admin)
    assert_equal 1, list.body["data"].size
    assert_operator list.body["total"], :>=, 2
    assert_equal [1, 1], [list.body["page"], list.body["limit"]]
    assert_equal 400, req("/api/v1/sms?limit=500", session: @admin).status
    assert_equal 400, req("/api/v1/sms/abc", session: @admin).status
  end

  test "marks read and bulk deletes" do
    on_runtime { simulator.inject_sms("+639175559999", "bulk me") }
    wait_for(3, "received") { Sim800c::SmsMessage.where(phone: "+639175559999").exists? }
    unread = req("/api/v1/sms?unread=true", session: @admin)
    message_ids = ids(unread)
    assert_operator message_ids.size, :>=, 1
    assert_equal message_ids.size, req("/api/v1/sms/read", body: { ids: message_ids }, session: @admin).body["updated"]
    del = req("/api/v1/sms/delete", body: { ids: message_ids }, session: @admin)
    assert_equal message_ids.sort, del.body["deleted"].sort
    assert_equal 404, req("/api/v1/sms/#{message_ids[0]}", session: @admin).status
  end

  test "retries every failed message at once" do
    res = req("/api/v1/sms", body: { to: "+639170000000, 09180000000", message: "retry all" }, session: @admin)
    sent_ids = ids(res)
    wait_for(4, "failed") { sent_ids.all? { |id| sms(id).status == "failed" } }
    failed = Sim800c::SmsMessage.where(status: "failed").pluck(:id).sort
    statuses = record_events("sms.status")
    retry_res = req("/api/v1/sms/retry-failed", method: :post, session: @admin)
    assert_equal 200, retry_res.status
    assert_equal failed, retry_res.body["retried"]
    wait_for(2, "requeue events") do
      (@requeued ||= []).concat(drain(statuses).select { |_, r| r[:status] == "queued" && r[:attempts].zero? }.map { |_, r| r[:id] })
      @requeued.sort == failed
    end
    wait_for(4, "failed again") { sent_ids.all? { |id| sms(id).status == "failed" } }
    assert(event_messages.any? { |m| m == "Re-queued 2 failed message(s)" })
  end

  test "retries and cancels single messages" do
    on_runtime do
      simulator.registration = 0
      @runtime.manager.poll
    end
    queued = req("/api/v1/sms", body: { to: "+639171234567", message: "cancel me" }, session: @admin).body["data"][0]
    cancelled = req("/api/v1/sms/#{queued['id']}/cancel", method: :post, session: @admin)
    assert_equal "cancelled", cancelled.body.dig("data", "status")
    assert_equal 409, req("/api/v1/sms/#{queued['id']}/cancel", method: :post, session: @admin).status
    retried = req("/api/v1/sms/#{queued['id']}/retry", method: :post, session: @admin)
    assert_equal ["queued", 0], [retried.body.dig("data", "status"), retried.body.dig("data", "attempts")]
    assert_equal 409, req("/api/v1/sms/#{queued['id']}/retry", method: :post, session: @admin).status
    on_runtime do
      simulator.registration = 1
      @runtime.manager.poll
    end
    wait_for(4, "delivered") { sms(queued["id"]).status == "delivered" }
    assert_equal 204, req("/api/v1/sms/#{queued['id']}", method: :delete, session: @admin).status
    assert_equal 404, req("/api/v1/sms/#{queued['id']}", method: :delete, session: @admin).status
  end

  # -- Idempotency-Key -----------------------------------------------------------------------------

  def send_sms(body, idempotency_key, session: nil, key: nil)
    headers = idempotency_key.nil? ? {} : { "Idempotency-Key" => idempotency_key }
    req("/api/v1/sms", body: body, session: session, key: key, headers: headers)
  end

  def count_body(text) = Sim800c::SmsMessage.where(body: text).count

  test "replays a repeated request without sending again" do
    first = send_sms({ to: "+639171230001, +639171230002", message: "idem once" }, "order-1001", session: @admin)
    assert_equal 202, first.status
    assert_nil first.headers["idempotent-replayed"]
    assert_equal 2, first.body["data"].size
    wait_for(4, "delivered") { ids(first).all? { |id| sms(id).status == "delivered" } }
    sleep 0.2
    events = record_events("sms.updated")
    again = send_sms({ to: ["+639171230001", "+639171230002"], message: "idem once" }, "order-1001", session: @admin)
    assert_equal 202, again.status
    assert_equal "true", again.headers["idempotent-replayed"]
    assert_equal ids(first), ids(again)
    assert_equal 2, count_body("idem once")
    sleep 0.2
    assert_empty drain(events), "a replay emits no events"
  end

  test "returns the current state of the original records, skipping deleted ones" do
    first = send_sms({ to: "+639171230003, +639171230004", message: "idem state" }, "order-1002", session: @admin)
    a, b = ids(first)
    wait_for(4, "delivered") { sms(a).status == "delivered" }
    Sim800c::SmsMessage.delete_ids([b])
    again = send_sms({ to: "+639171230003, +639171230004", message: "idem state" }, "order-1002", session: @admin)
    assert_equal 202, again.status
    assert_equal [a], ids(again)
    assert_equal "delivered", again.body["data"][0]["status"]
  end

  test "rejects an Idempotency-Key reused for a different request" do
    key = create_key(@admin, ["sms:send"])
    assert_equal 202, send_sms({ to: "+639171230005", message: "idem first" }, "order-1003", key: key).status
    changed = send_sms({ to: "+639171230005", message: "idem second" }, "order-1003", key: key)
    assert_equal [409, "idempotency_key_reused"], [changed.status, changed.body.dig("error", "code")]
    assert_match(/already used with a different request/, changed.body.dig("error", "message"))
    assert_equal 409, send_sms({ to: "+639171230005", message: "idem first", priority: 5 }, "order-1003", key: key).status
    assert_equal 0, count_body("idem second")
  end

  test "scopes Idempotency-Keys to the API key or user that sent them" do
    k1 = create_key(@admin, ["sms:send"])
    k2 = create_key(@admin, ["sms:send"])
    body = { to: "+639171230006", message: "idem scoped" }
    responses = [send_sms(body, "shared-key", key: k1), send_sms(body, "shared-key", key: k2),
                 send_sms(body, "shared-key", session: @admin)]
    responses.each do |r|
      assert_equal 202, r.status
      assert_nil r.headers["idempotent-replayed"]
    end
    assert_equal 3, responses.flat_map { |r| ids(r) }.uniq.size
    assert_equal 3, count_body("idem scoped")
    assert_equal "true", send_sms(body, "shared-key", key: k1).headers["idempotent-replayed"]
  end

  test "sends twice without the header" do
    body = { to: "+639171230007", message: "idem none" }
    r1 = send_sms(body, nil, session: @admin)
    r2 = send_sms(body, nil, session: @admin)
    assert_equal 202, r2.status
    assert_nil r2.headers["idempotent-replayed"]
    refute_equal ids(r1), ids(r2)
    assert_equal 2, count_body("idem none")
  end

  test "rejects invalid Idempotency-Keys" do
    body = { to: "+639171230008", message: "idem invalid" }
    ["has space", "x" * 256].each do |bad|
      res = send_sms(body, bad, session: @admin)
      assert_equal [400, "bad_request"], [res.status, res.body.dig("error", "code")], bad
      assert_match(/Idempotency-Key/, res.body.dig("error", "message"))
    end
    assert_equal 0, count_body("idem invalid")
    assert_equal 202, send_sms(body, "x" * 255, session: @admin).status
  end

  test "does not use up the Idempotency-Key when the request fails" do
    too_long = send_sms({ to: "+639171230009", message: "x" * 1200 }, "order-1004", session: @admin)
    assert_equal 400, too_long.status
    assert_match(/too long/, too_long.body.dig("error", "message"))
    assert_equal 400, send_sms({ to: "call me", message: "idem retry" }, "order-1004", session: @admin).status
    fixed = send_sms({ to: "+639171230009", message: "idem retry" }, "order-1004", session: @admin)
    assert_equal 202, fixed.status
    assert_nil fixed.headers["idempotent-replayed"]
    assert_equal 1, count_body("idem retry")
  end

  test "treats an expired Idempotency-Key as new and prunes it" do
    age = -> { Sim800c::IdempotencyKey.where(idempotency_key: "order-1005").update_all(["created_at = ?", 25.hours.ago]) }
    body = { to: "+639171230010", message: "idem expired" }
    first = send_sms(body, "order-1005", session: @admin)
    age.call
    second = send_sms(body, "order-1005", session: @admin)
    assert_equal 202, second.status
    assert_nil second.headers["idempotent-replayed"]
    refute_equal ids(first), ids(second)
    assert_equal "true", send_sms(body, "order-1005", session: @admin).headers["idempotent-replayed"]
    age.call
    assert_operator Sim800c::IdempotencyKey.prune!, :>=, 1
    refute Sim800c::IdempotencyKey.exists?(idempotency_key: "order-1005")
  end

  # -- calls, modem and status ---------------------------------------------------------------------

  test "places and ends a call" do
    dial = req("/api/v1/calls", body: { number: "+639171234567" }, session: @admin)
    assert_equal 202, dial.status
    wait_for(3, "active") { req("/api/v1/calls/active", session: @admin).body.dig("data", "status") == "active" }
    assert_equal dial.body.dig("data", "id"), req("/api/v1/calls/active", session: @admin).body.dig("data", "id")
    assert_equal 204, req("/api/v1/calls/dtmf", body: { digits: "12#" }, session: @admin).status
    assert_equal 400, req("/api/v1/calls/dtmf", body: { digits: "12x" }, session: @admin).status
    hung = req("/api/v1/calls/hangup", method: :post, session: @admin)
    assert_equal "completed", hung.body.dig("data", "status")
    assert_equal 409, req("/api/v1/calls/hangup", method: :post, session: @admin).status
    history = req("/api/v1/calls?direction=outbound", session: @admin)
    assert_equal [dial.body.dig("data", "id")], ids(history)
    assert_equal 400, req("/api/v1/calls", body: { number: "*123#" }, session: @admin).status
  end

  test "runs USSD sessions and requires calls:write to send" do
    menu = req("/api/v1/ussd", body: { code: "*143#" }, session: @admin)
    assert_equal [200, "open"], [menu.status, menu.body.dig("data", "status")]
    assert_equal 400, req("/api/v1/ussd/reply", body: { text: "1\"" }, session: @admin).status
    done = req("/api/v1/ussd/reply", body: { text: "1" }, session: @admin)
    assert_match(/balance/, done.body.dig("data", "response"))
    assert_equal menu.body.dig("data", "id"), req("/api/v1/ussd", session: @admin).body.dig("data", "id")
    assert_equal 409, req("/api/v1/ussd/cancel", method: :post, session: @admin).status

    key = create_key(@admin, ["calls:read"])
    assert_equal 200, req("/api/v1/ussd", key: key).status
    assert_equal 403, req("/api/v1/ussd", body: { code: "*123#" }, key: key).status
  end

  test "exposes modem status and blocks dangerous AT commands" do
    status = req("/api/v1/modem", session: @admin)
    assert_equal "ready", status.body.dig("data", "connection")
    assert_equal true, status.body["canOperate"]
    at = req("/api/v1/modem/at", body: { command: "AT+CSQ" }, session: @admin)
    assert_equal true, at.body["ok"]
    assert_match(/\A\+CSQ:/, at.body["lines"][0])
    assert_equal 400, req("/api/v1/modem/at", body: { command: "AT+CMGF=1" }, session: @admin).status
    assert_equal 400, req("/api/v1/modem/at", body: { command: "ping" }, session: @admin).status
    traffic = req("/api/v1/modem/traffic", session: @admin)
    assert(traffic.body["data"].any? { |e| e["line"] == "AT+CSQ" })
    key = create_key(@admin, %w[modem:read modem:write])
    assert_equal 403, req("/api/v1/modem/at", body: { command: "AT" }, key: key).status
    assert(req("/api/v1/modem/events?limit=5", key: key).body["data"].any? { |e| e["message"].start_with?("AT console") })
    assert_equal 202, req("/api/v1/modem/reconnect", method: :post, key: key).status
    wait_for(5, "ready again") { req("/api/v1/modem", key: key).body["canOperate"] }
  end

  test "reports status with counters for the caller's scopes" do
    status = req("/api/v1/status", session: @admin)
    assert_equal %w[modem canOperate reason call sms calls simulator], status.body.keys
    assert_equal true, status.body["simulator"]
    assert status.body["sms"].key?("unread")
    key = create_key(@admin, ["modem:read"])
    limited = req("/api/v1/status", key: key)
    assert_nil limited.body["sms"]
    assert_nil limited.body["calls"]
  end

  test "drives the simulator" do
    res = req("/api/v1/simulator/incoming-sms", body: { from: "+639175550123", message: "from sim" }, session: @admin)
    assert_equal 202, res.status
    wait_for(3, "received") { Sim800c::SmsMessage.exists?(body: "from sim") }
    assert_equal 200, req("/api/v1/simulator/signal", body: { rssi: 9 }, session: @admin).status
    wait_for(3, "poor signal") { req("/api/v1/modem", session: @admin).body.dig("data", "signal", "quality") == "poor" }
    assert_equal 400, req("/api/v1/simulator/signal", body: { rssi: 40 }, session: @admin).status
    assert_equal 21, req("/api/v1/simulator", session: @admin).body.dig("data", "storageCapacity").then { 21 }
  end

  test "answers 503 for live operations while the runtime is down" do
    stop_runtime
    res = req("/api/v1/calls", body: { number: "+639171234567" }, session: @admin)
    assert_equal [503, "modem_unavailable"], [res.status, res.body.dig("error", "code")]
    status = req("/api/v1/status", session: @admin)
    assert_equal [200, "disconnected", false], [status.status, status.body.dig("modem", "connection"), status.body["canOperate"]]
    # Messages can still be queued; they go out when the runtime starts.
    queued = req("/api/v1/sms", body: { to: "+639171234567", message: "later" }, session: @admin)
    assert_equal 202, queued.status
    health = req("/healthz")
    assert_equal({ "ok" => true, "modem" => "disconnected", "runtime" => "offline" }, health.body)
    start_runtime
    wait_for(5, "delivered") { sms(queued.body["data"][0]["id"]).status == "delivered" }
  end

  test "serves the dashboard and its versioned assets with security headers" do
    res = req("/")
    assert_equal 200, res.status
    assert_match(/script-src 'self'/, res.headers["content-security-policy"])
    assert_equal "nosniff", res.headers["x-content-type-options"]
    assert_includes res.body, %(<meta name="sim800c-base" content="/sms-gateway" />)
    assert_includes res.body, %(src="/sms-gateway/static/#{Sim800c::VERSION}/js/app.js")
    js = req("/static/#{Sim800c::VERSION}/js/lib/api.js")
    assert_equal 200, js.status
    assert_match(%r{javascript}, js.headers["content-type"])
    assert_equal 200, req("/static/#{Sim800c::VERSION}/fonts/doto-latin-full-normal.woff2").status
    assert_equal 404, req("/static/#{Sim800c::VERSION}/../config/routes.rb").status
    assert_equal 404, req("/static/0.0.0/js/app.js").status
    assert_equal({ "ok" => true, "modem" => "ready", "runtime" => "running" }, req("/healthz").body)
  end

  test "answers unknown API routes with a JSON 404" do
    res = req("/api/v1/nope")
    assert_equal [404, "not_found", "No route for GET /api/v1/nope"],
                 [res.status, res.body.dig("error", "code"), res.body.dig("error", "message")]
  end

  # -- USSD history --------------------------------------------------------------------------------

  def session_ids(query) = ids(req("/api/v1/ussd/sessions?#{query}", session: @admin))

  test "lists and fetches persisted USSD sessions, with filters" do
    done = req("/api/v1/ussd", body: { code: "*123#" }, session: @admin).body["data"]
    assert_equal "completed", done["status"]
    assert_equal done, req("/api/v1/ussd/sessions/#{done['id']}", session: @admin).body["data"]
    assert_equal %w[outbound inbound], done["messages"].map { |m| m["direction"] }

    key = create_key(@admin, %w[calls:read calls:write])
    unsupported = req("/api/v1/ussd", body: { code: "*555#" }, key: key).body["data"]
    assert_equal %w[failed api], [unsupported["status"], unsupported["source"]]

    page = req("/api/v1/ussd/sessions?limit=1", key: key)
    assert_equal [1, 1, [unsupported["id"]]], [page.body["page"], page.body["limit"], ids(page)]
    assert_operator page.body["total"], :>=, 2
    assert_includes session_ids("source=dashboard&status=completed"), done["id"]
    refute_includes session_ids("source=dashboard"), unsupported["id"]
    assert_equal [unsupported["id"]], session_ids("source=api&status=failed&q=*555")
    by_reply = session_ids("q=P123.45")
    assert(by_reply.include?(done["id"]) && !by_reply.include?(unsupported["id"]))
    assert_equal [], session_ids("q=%25")
    assert_equal 400, req("/api/v1/ussd/sessions?status=done", session: @admin).status
    assert_equal 404, req("/api/v1/ussd/sessions/999999", session: @admin).status
  end

  test "deletes finished USSD sessions but not the one in progress" do
    done = req("/api/v1/ussd", body: { code: "*123#" }, session: @admin).body["data"]
    menu = req("/api/v1/ussd", body: { code: "*143#" }, session: @admin).body["data"]
    assert_equal "open", menu["status"]
    assert_equal 409, req("/api/v1/ussd/sessions/#{menu['id']}", method: :delete, session: @admin).status
    assert_equal 409, req("/api/v1/ussd/sessions/delete", body: { ids: [done["id"], menu["id"]] }, session: @admin).status
    assert_equal 200, req("/api/v1/ussd/sessions/#{done['id']}", session: @admin).status

    reader = create_key(@admin, ["calls:read"])
    assert_equal 403, req("/api/v1/ussd/sessions/#{done['id']}", method: :delete, key: reader).status

    assert_equal 200, req("/api/v1/ussd/cancel", method: :post, session: @admin).status
    deleted = req("/api/v1/ussd/sessions/delete", body: { ids: [done["id"], menu["id"], 999_999] }, session: @admin)
    assert_equal [done["id"], menu["id"]], deleted.body["deleted"]
    assert_equal 404, req("/api/v1/ussd/sessions/#{menu['id']}", session: @admin).status
    assert_equal 404, req("/api/v1/ussd/sessions/#{menu['id']}", method: :delete, session: @admin).status
  end
end
