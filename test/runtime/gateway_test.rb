# frozen_string_literal: true

require "test_helper"

# End-to-end flows: services + modem manager + AT client + PDU codec against the simulator.
class GatewayTest < ActiveSupport::TestCase
  def queue_sms(to, text, **options)
    records, = Sim800c::SmsMessage.enqueue(to: Array(to), text: text, source: "api", **options)
    on_runtime { @runtime.sms.kick }
    records
  end

  # -- modem connection ---------------------------------------------------------------------------

  test "recovers from a USB unplug and sends SMS queued while offline" do
    start_runtime(rpc: false)
    on_runtime { simulator.unplug(0.6) }
    wait_for(2, "disconnect detected") { on_runtime { @runtime.manager.status[:connection] } != "ready" }
    queued = queue_sms("+639171234567", "sent after reconnect").first
    wait_for(8, "reconnected") { on_runtime { @runtime.manager.can_operate? } }
    wait_for(4, "delivered") { sms(queued.id).status == "delivered" }
    assert_equal 1, sms(queued.id).attempts
    assert(event_messages.any? { |m| m.start_with?("Modem disconnected") })
  end

  test "pauses sending while the network is unavailable" do
    start_runtime(rpc: false)
    on_runtime do
      simulator.registration = 0
      @runtime.manager.poll
    end
    refute on_runtime { @runtime.manager.can_operate? }
    m = queue_sms("+639171234567", "wait for network").first
    sleep 0.4
    assert_equal "queued", sms(m.id).status
    assert_equal 0, sms(m.id).attempts
    on_runtime do
      simulator.registration = 1
      @runtime.manager.poll
    end
    wait_for(4, "delivered after network returns") { sms(m.id).status == "delivered" }
  end

  test "re-queues messages interrupted by a restart" do
    configure_for_tests
    m = Sim800c::SmsMessage.enqueue(to: ["+639171234567"], text: "interrupted", source: "api").first.first
    Sim800c::SmsMessage.where(id: m.id).update_all(status: "sending", attempts: 1)
    start_runtime(rpc: false)
    wait_for(4, "delivered") { sms(m.id).status == "delivered" }
    assert(event_messages.any? { |msg| msg.match?(/Re-queued 1 message\(s\) interrupted by a restart/) })
  end

  # -- SMS ------------------------------------------------------------------------------------------

  test "sends asynchronously and tracks delivery reports" do
    start_runtime(rpc: false)
    events = record_events("sms.status")
    m = queue_sms("+639171234567", "Hello 👋").first
    assert_equal "queued", m.status
    assert_equal "ucs2", m.encoding
    wait_for(4, "delivered") { sms(m.id).status == "delivered" }
    wait_for(1, "status events") { events.size >= 2 }
    assert_equal %w[sent delivered], drain(events).map { |_, r| r[:status] }
    assert sms(m.id).delivered_at
  end

  test "sends multipart messages and needs every part delivered" do
    start_runtime(rpc: false)
    text = "Part of a long message. " * 20
    m = queue_sms("09171234567", text).first
    assert_equal 4, m.parts
    wait_for(5, "delivered") { sms(m.id).status == "delivered" }
    sent = on_runtime { simulator.sent.select { |s| s[:to] == "09171234567" } }
    assert_equal 4, sent.size
    assert_equal text, sent.map { |s| s[:text] }.join
  end

  test "fails permanent errors immediately and surfaces the reason" do
    start_runtime(rpc: false)
    m = queue_sms("+639170000000", "bad").first
    wait_for(3, "failed") { sms(m.id).status == "failed" }
    assert_equal 1, sms(m.id).attempts
    assert_match(/Unassigned/, sms(m.id).error)
  end

  test "retries transient errors with backoff, then gives up" do
    start_runtime(rpc: false, "mock.sms_failure_rate" => 1.0, "sms.max_attempts" => 3)
    m = queue_sms("+639171234567", "congested").first
    wait_for(6, "failed after retries") { sms(m.id).status == "failed" }
    assert_equal 3, sms(m.id).attempts
    assert_match(/congestion/i, sms(m.id).error)
    assert_equal "queued", Sim800c::SmsMessage.retry!(m.id).status
  end

  test "marks undelivered messages from status reports" do
    start_runtime(rpc: false)
    m = queue_sms("+639171114444", "never arrives").first
    wait_for(4, "failed via report") { sms(m.id).status == "failed" }
    assert_match(/Validity period expired/, sms(m.id).error)
  end

  test "rejects messages longer than the part limit and invalid numbers" do
    configure_for_tests("sms.max_parts" => 2)
    error = assert_raises(Sim800c::AppError) { Sim800c::SmsMessage.enqueue(to: ["+639171234567"], text: "x" * 400, source: "api") }
    assert_match(/too long/, error.message)
    error = assert_raises(Sim800c::AppError) { Sim800c::SmsMessage.enqueue(to: ["12;ATH"], text: "x", source: "api") }
    assert_match(/Invalid phone number/, error.message)
  end

  test "receives, reassembles and removes multipart messages from the SIM" do
    start_runtime(rpc: false)
    received = record_events("sms.received")
    text = "Incoming long message ✓ " * 10
    on_runtime { simulator.inject_sms("+639175550000", text) }
    wait_for(3, "received") { received.size == 1 }
    assert_equal text, received.pop[1][:body]
    wait_for(2, "SIM emptied") { on_runtime { simulator.snapshot[:storageUsed] }.zero? }
    record = Sim800c::SmsMessage.where(direction: "inbound").sole
    assert_equal 4, record.parts # 240 UCS-2 characters at 67 per part
    refute record.as_api[:read]
    assert_equal "+639170000130", record.smsc
  end

  test "imports messages that were stored while the gateway was offline" do
    start_runtime(rpc: false)
    on_runtime { @runtime.manager.remove_all_listeners(:event) } # simulate missing the +CMTI notifications
    on_runtime { simulator.inject_sms("+639175550001", "stored while offline") }
    on_runtime { @runtime.reactor.await(@runtime.sms.sync_inbox) }
    assert_equal "stored while offline", Sim800c::SmsMessage.where(direction: "inbound").sole.body
    assert_equal 0, on_runtime { simulator.snapshot[:storageUsed] }
  end

  test "does not import the same message twice" do
    start_runtime(rpc: false)
    on_runtime { simulator.inject_sms("+639175550005", "only once") }
    wait_for(3, "received") { Sim800c::SmsMessage.where(direction: "inbound").count == 1 }
    record = Sim800c::SmsMessage.where(direction: "inbound").sole
    # The same PDU read again (e.g. the SIM was not emptied before a crash) is ignored.
    pdu = Sim800c::PDU.encode_deliver(from: "+639175550005", text: "only once", smsc: "+639170000130",
                                      timestamp: record.received_at).first
    on_runtime { @runtime.manager.emit(:event, { type: :sms_direct, pdu: pdu.pdu, length: pdu.tpdu_length }) }
    on_runtime { @runtime.reactor.await(@runtime.sms.sync_inbox) }
    assert_equal 1, Sim800c::SmsMessage.where(direction: "inbound").count
  end

  test "marks read, searches and deletes" do
    start_runtime(rpc: false)
    on_runtime do
      simulator.inject_sms("+639175550002", "apples")
      simulator.inject_sms("+639175550003", "oranges")
    end
    wait_for(3, "two messages") { Sim800c::SmsMessage.count == 2 }
    found, total = Sim800c::SmsMessage.search(q: "ORANG", page: 1, limit: 10)
    assert_equal 1, total
    assert_equal 1, Sim800c::SmsMessage.mark_read([found.first.id], true)
    assert_equal 1, Sim800c::SmsMessage.stats[:unread]
    all = Sim800c::SmsMessage.pluck(:id)
    assert_equal all.sort, Sim800c::SmsMessage.delete_ids(all)
    assert_equal 0, Sim800c::SmsMessage.count
  end

  # -- calls ----------------------------------------------------------------------------------------

  test "dials, connects and hangs up an outgoing call" do
    start_runtime(rpc: false)
    c = on_runtime { @runtime.calls.dial("+639171234567", { source: "dashboard" }) }
    wait_for(3, "answered") { call_record(c[:id]).status == "active" }
    sleep 1.1
    ended = on_runtime { @runtime.calls.hangup }
    assert_equal "completed", ended[:status]
    assert_operator ended[:duration], :>=, 1
    assert_nil on_runtime { @runtime.calls.active }
  end

  test "reports busy, rejected and unanswered outgoing calls" do
    start_runtime(rpc: false)
    busy = on_runtime { @runtime.calls.dial("+639171230000", { source: "api" }) }
    wait_for(3, "busy") { call_record(busy[:id]).status == "busy" }

    rejected = on_runtime { @runtime.calls.dial("+639171230888", { source: "api" }) }
    wait_for(3, "remote rejected") { call_record(rejected[:id]).status == "no_answer" }

    cancelled = on_runtime { @runtime.calls.dial("+639171230999", { source: "api" }) }
    wait_for(2, "ringing") { call_record(cancelled[:id]).status == "ringing" }
    assert_equal "cancelled", on_runtime { @runtime.calls.hangup }[:status]
  end

  test "refuses to dial without network or while another call is active" do
    start_runtime(rpc: false)
    on_runtime { @runtime.calls.dial("+639171234567", { source: "api" }) }
    error = assert_raises(Sim800c::AppError) { on_runtime { @runtime.calls.dial("+639170000001", { source: "api" }) } }
    assert_match(/already in progress/, error.message)
    on_runtime { @runtime.calls.hangup }
    on_runtime do
      simulator.registration = 3
      @runtime.manager.poll
    end
    error = assert_raises(Sim800c::AppError) { on_runtime { @runtime.calls.dial("+639170000001", { source: "api" }) } }
    assert_match(/Not registered/, error.message)
    assert_equal 503, error.status
  end

  test "answers an incoming call with caller ID" do
    start_runtime(rpc: false)
    incoming = record_events("call.incoming")
    on_runtime { simulator.inject_call("+639178889999") }
    wait_for(2, "caller id") { on_runtime { @runtime.calls.active&.dig(:phone) } == "+639178889999" }
    assert_includes drain(incoming).map { |_, c| c[:phone] }, "+639178889999"
    answered = on_runtime { @runtime.calls.answer }
    assert_equal "active", answered[:status]
    on_runtime { simulator.remote_hangup }
    wait_for(2, "remote hangup") { call_record(answered[:id]).status == "completed" }
    assert_equal "Remote party hung up", call_record(answered[:id]).end_reason
  end

  test "records rejected and missed incoming calls" do
    start_runtime(rpc: false)
    on_runtime { simulator.inject_call("+639170000002") }
    wait_for(2, "ringing") { on_runtime { @runtime.calls.active } }
    assert_equal "rejected", on_runtime { @runtime.calls.reject }[:status]

    on_runtime { simulator.inject_call("+639170000003") }
    wait_for(2, "ringing again") { on_runtime { @runtime.calls.active } }
    id = on_runtime { @runtime.calls.active[:id] }
    on_runtime { simulator.remote_hangup }
    wait_for(2, "missed") { call_record(id).status == "missed" }
    assert_equal 1, Sim800c::Call.stats[:missedToday]
  end

  test "ends the call record when the modem disconnects mid-call" do
    start_runtime(rpc: false)
    c = on_runtime { @runtime.calls.dial("+639171234567", { source: "api" }) }
    wait_for(3, "active") { call_record(c[:id]).status == "active" }
    on_runtime { simulator.unplug(0.3) }
    wait_for(2, "finalised") { call_record(c[:id]).status == "completed" }
    assert_equal "Modem disconnected", call_record(c[:id]).end_reason
  end

  test "finalises calls interrupted by a restart" do
    configure_for_tests
    answered = Sim800c::Call.create!(direction: "outbound", phone: "+1", status: "active", source: "api",
                                     started_at: 1.minute.ago, answered_at: 30.seconds.ago)
    ringing = Sim800c::Call.create!(direction: "inbound", phone: "+2", status: "ringing", source: "modem",
                                    started_at: 10.seconds.ago)
    start_runtime(rpc: false)
    assert_equal ["completed", "Interrupted by application restart"], [answered.reload.status, answered.end_reason]
    assert_operator answered.duration, :>=, 29
    assert_equal ["failed", 0], [ringing.reload.status, ringing.duration]
  end

  # -- USSD -----------------------------------------------------------------------------------------

  test "sends a USSD code and returns the network reply" do
    start_runtime(rpc: false)
    s = on_runtime { @runtime.ussd.send_code("*123#", { source: "api" }) }
    assert_equal "completed", s[:status]
    assert_match(/balance is P123\.45/, s[:response])
    assert_equal %w[outbound inbound], s[:messages].map { |m| m[:direction] }
    assert(Sim800c::EventLogEntry.where(category: "ussd").pluck(:message).any? { |m| m.match?(/\*123#: Your balance/) })
  end

  test "navigates a multi-line menu" do
    start_runtime(rpc: false)
    menu = on_runtime { @runtime.ussd.send_code("*143#", { source: "dashboard" }) }
    assert_equal "open", menu[:status]
    assert_equal "Services\n1 Balance\n2 Promos", menu[:response]
    done = on_runtime { @runtime.ussd.reply("2") }
    assert_equal "completed", done[:status]
    assert_equal "No promos available right now.", done[:response]
    error = assert_raises(Sim800c::AppError) { on_runtime { @runtime.ussd.reply("1") } }
    assert_match(/no USSD menu/, error.message)
  end

  test "closes an open menu when cancelled or when a new code is dialed" do
    start_runtime(rpc: false)
    on_runtime { @runtime.ussd.send_code("*143#", { source: "api" }) }
    assert_equal "cancelled", on_runtime { @runtime.ussd.cancel }[:status]
    error = assert_raises(Sim800c::AppError) { on_runtime { @runtime.ussd.cancel } }
    assert_match(/no USSD session/, error.message)

    first = on_runtime { @runtime.ussd.send_code("*143#", { source: "api" }) }
    second = on_runtime { @runtime.ussd.send_code("*123#", { source: "api" }) }
    assert_equal "completed", second[:status]
    refute_equal first[:id], second[:id]
    assert_equal "cancelled", Sim800c::UssdSession.find(first[:id]).status
  end

  test "reports unsupported codes and unanswered requests" do
    start_runtime(rpc: false, "calls.ussd_timeout" => 1)
    unsupported = on_runtime { @runtime.ussd.send_code("*555#", { source: "api" }) }
    assert_equal "failed", unsupported[:status]
    assert_match(/not supported/, unsupported[:error])

    silent = on_runtime { @runtime.ussd.send_code("*999#", { source: "api" }) }
    assert_equal "failed", silent[:status]
    assert_match(/No reply/, silent[:error])
  end

  test "rejects USSD codes on the voice call API and invalid codes" do
    start_runtime(rpc: false)
    error = assert_raises(Sim800c::AppError) { on_runtime { @runtime.calls.dial("*123#", { source: "api" }) } }
    assert_match(/USSD code/, error.message)
    ["09171234567", '*1"#'].each do |code|
      error = assert_raises(Sim800c::AppError) { on_runtime { @runtime.ussd.send_code(code, { source: "api" }) } }
      assert_match(/Invalid USSD code/, error.message)
    end
  end

  test "keeps every USSD session, with its messages, in the database" do
    start_runtime(rpc: false)
    menu = on_runtime { @runtime.ussd.send_code("*143#", { source: "dashboard", user_id: nil }) }
    done = on_runtime { @runtime.ussd.reply("1") }
    assert_equal menu[:id], done[:id]
    assert_equal done, Sim800c::UssdSession.find(done[:id]).as_api
    assert_equal [["outbound", "*143#"], ["inbound", "Services\n1 Balance\n2 Promos"], ["outbound", "1"],
                  ["inbound", "Your balance is P123.45, valid until 31-12-2026."]],
                 done[:messages].map { |m| [m[:direction], m[:text]] }
    assert_equal "dashboard", Sim800c::UssdSession.find(done[:id]).source

    # A message pushed by the network starts a session of its own.
    on_runtime { @runtime.manager.emit(:event, { type: :ussd, state: :done, text: "Promo: 1GB for P10" }) }
    pushed = on_runtime { @runtime.ussd.current }
    assert_equal [nil, "modem", "completed"], [pushed[:code], pushed[:source], pushed[:status]]
    assert_operator pushed[:id], :>, done[:id]
    assert_equal pushed, Sim800c::UssdSession.find(pushed[:id]).as_api
    assert_equal [pushed[:id], done[:id]], Sim800c::UssdSession.search(page: 1, limit: 10).first.map(&:id)
  end

  test "emits ussd.ended once when a session finishes, not when a menu opens" do
    start_runtime(rpc: false, "calls.ussd_timeout" => 1)
    ended = record_events("ussd.ended")
    done = on_runtime { @runtime.ussd.send_code("*123#", { source: "api" }) }
    menu = on_runtime { @runtime.ussd.send_code("*143#", { source: "api" }) }
    assert_equal "open", menu[:status]
    on_runtime { @runtime.ussd.cancel }
    silent = on_runtime { @runtime.ussd.send_code("*999#", { source: "api" }) }
    assert_equal "failed", silent[:status]
    sleep 0.3 # nothing arrives late, e.g. after AT+CUSD=2
    assert_equal [[done[:id], "completed"], [menu[:id], "cancelled"], [silent[:id], "failed"]],
                 drain(ended).map { |_, s| [s[:id], s[:status]] }
  end

  test "fails USSD sessions cut short by a restart" do
    start_runtime(rpc: false)
    menu = on_runtime { @runtime.ussd.send_code("*143#", { source: "dashboard" }) }
    assert_equal "open", menu[:status]
    stop_runtime # stopping does not report a status change, so the menu stays open in the database

    @runtime = Sim800c::Runtime.new(rpc: false).start
    wait_for(5, "modem ready") { on_runtime { @runtime.manager.can_operate? } }
    interrupted = Sim800c::UssdSession.find(menu[:id]).as_api
    assert_equal ["failed", "Interrupted by a restart"], [interrupted[:status], interrupted[:error]]
    assert_equal menu[:messages], interrupted[:messages]
    assert_equal interrupted, on_runtime { @runtime.ussd.current } # GET /ussd still returns the latest session
    assert(Sim800c::EventLogEntry.where(category: "ussd", level: "warn").pluck(:message).any? { |m| m.match?(/interrupted by a restart/) })
  end
end
