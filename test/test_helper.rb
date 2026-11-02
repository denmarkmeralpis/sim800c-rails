# frozen_string_literal: true

# Helper for tests that need Rails: the dummy app, the engine's tables, and runtime helpers.

ENV["RAILS_ENV"] = "test"
DB_PATH = File.expand_path("dummy/db/test.sqlite3", __dir__)
Dir.glob("#{DB_PATH}*").each { |f| File.delete(f) }

require_relative "dummy/config/environment"
require "rails/test_help"
require "unit_helper"
require "support/recording_events"

ActiveRecord::Migration.verbose = false
ActiveRecord::MigrationContext.new(File.expand_path("../db/migrate", __dir__)).migrate

module RuntimeHelpers
  TABLES = Sim800c::Runtime::TABLES

  # Settings for a runtime against the simulator at 20x speed (like sms-gateway's testConfig).
  def configure_for_tests(**overrides)
    Sim800c.reset_config!
    Sim800c.configure do |c|
      c.modem.driver = :mock
      c.modem.poll_interval = 1
      c.modem.command_timeout = 2
      c.modem.reconnect_min = 0.2
      c.modem.reconnect_max = 1
      c.mock.time_scale = 0.05
      c.sms.retry_base = 0.1
      c.sms.queue_poll_interval = 0.5
      c.calls.poll_interval = 0.3
      c.auth.admin_password = "admin-password"
      c.rpc.url = "unix://#{Rails.root.join('tmp/sockets/sim800c-test.sock')}"
      c.lock_file = Rails.root.join("tmp/pids/sim800c-test.lock").to_s
      overrides.each do |path, value|
        section, key = path.to_s.split(".", 2)
        key ? c.public_send(section).public_send("#{key}=", value) : c.public_send("#{section}=", value)
      end
    end
  end

  def truncate_tables
    connection = ActiveRecord::Base.connection
    connection.disable_referential_integrity do
      TABLES.each { |t| connection.execute("DELETE FROM #{t}") }
    end
  end

  # Starts a runtime against the simulator and waits until it can operate.
  def start_runtime(rpc: true, **overrides)
    configure_for_tests(**overrides)
    @runtime = Sim800c::Runtime.new(rpc: rpc).start
    wait_for(5, "modem ready") { on_runtime { @runtime.manager.can_operate? } }
    @runtime
  end

  def stop_runtime
    @runtime&.stop
    @runtime = nil
  end

  def on_runtime(timeout = 30, &block) = @runtime.call(timeout: timeout, &block)
  def simulator = @runtime.simulator
  def sms(id) = Sim800c::SmsMessage.find(id)
  def call_record(id) = Sim800c::Call.find(id)
  def event_messages = Sim800c::EventLogEntry.order(:id).pluck(:message)

  # Records bus events of the given names (listeners run on the reactor; the list is thread-safe).
  def record_events(*names)
    events = Queue.new
    on_runtime { names.each { |n| @runtime.bus.on(n) { |data| events << [n, data] } } }
    events
  end

  def drain(queue)
    out = []
    out << queue.pop until queue.empty?
    out
  end
end

class ActiveSupport::TestCase
  include Sim800cTestHelpers
  include RuntimeHelpers

  # The runtime writes from its own thread and connection, so tests cannot run inside a transaction.
  self.use_transactional_tests = false

  setup { truncate_tables }
  teardown { stop_runtime }
end
