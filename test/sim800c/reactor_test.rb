# frozen_string_literal: true

require "unit_helper"

class ReactorTest < Minitest::Test
  def setup
    @reactor = Sim800c::Reactor.new.start
  end

  def teardown
    @reactor.stop
  end

  def test_call_runs_on_the_reactor_thread_and_returns_the_result
    thread = @reactor.call(timeout: 2) { Thread.current }
    assert_same @reactor.thread, thread
    refute @reactor.on_thread?
  end

  def test_call_propagates_errors
    error = assert_raises(ArgumentError) { @reactor.call(timeout: 2) { raise ArgumentError, "boom" } }
    assert_equal "boom", error.message
  end

  def test_call_times_out
    assert_raises(Sim800c::TimeoutError) { @reactor.call(timeout: 0.05) { @reactor.sleep(1) } }
  end

  def test_tasks_run_until_their_first_await_like_async_functions
    order = @reactor.call(timeout: 2) do
      order = []
      gate = Sim800c::Promise.new
      promise = @reactor.task do
        order << :started
        @reactor.await(gate)
        order << :resumed
        :done
      end
      order << :after_spawn
      @reactor.after(0.01) { gate.resolve }
      order << @reactor.await(promise)
      order
    end
    assert_equal %i[started after_spawn resumed done], order
  end

  def test_await_raises_the_rejection_error
    result = @reactor.call(timeout: 2) do
      failing = @reactor.task do
        @reactor.sleep(0.01)
        raise "nope"
      end
      begin
        @reactor.await(failing)
      rescue RuntimeError => e
        "caught #{e.message}"
      end
    end
    assert_equal "caught nope", result
  end

  def test_timers_fire_in_deadline_order_and_can_be_cancelled
    fired = Thread::Queue.new
    @reactor.post do
      @reactor.after(0.06) { fired << :c }
      @reactor.after(0.02) { fired << :a }
      @reactor.after(0.04) { fired << :b }
      @reactor.after(0.03) { fired << :never }.cancel
    end
    assert_equal %i[a b c], 3.times.map { fired.pop(timeout: 2) }
    assert_nil fired.pop(timeout: 0.05)
  end

  def test_timers_with_the_same_deadline_keep_insertion_order
    fired = Thread::Queue.new
    @reactor.post { 5.times { |i| @reactor.after(0) { fired << i } } }
    assert_equal [0, 1, 2, 3, 4], 5.times.map { fired.pop(timeout: 2) }
  end

  def test_every_repeats_until_cancelled
    count = 0
    timer = nil
    @reactor.post { timer = @reactor.every(0.01) { count += 1 } }
    wait_for(2, "repeats") { count >= 3 }
    @reactor.call(timeout: 2) { timer.cancel }
    seen = count
    sleep 0.05
    assert_includes [seen, seen + 1], count
  end

  def test_defer_runs_blocking_work_off_the_reactor
    result = @reactor.call(timeout: 2) do
      @reactor.await(@reactor.defer { [Thread.current.name, :value] })
    end
    assert_equal ["sim800c-reactor-defer", :value], result
  end

  def test_other_work_runs_while_a_task_is_suspended
    log = @reactor.call(timeout: 2) do
      log = []
      slow = @reactor.task do
        @reactor.sleep(0.05)
        log << :slow
      end
      fast = @reactor.task do
        @reactor.sleep(0.01)
        log << :fast
      end
      @reactor.await(slow)
      @reactor.await(fast)
      log
    end
    assert_equal %i[fast slow], log
  end

  def test_go_logs_failures_without_stopping_the_loop
    @reactor.go { raise "ignored" }
    assert_equal 42, @reactor.call(timeout: 2) { 42 }
  end

  def test_await_guard_runs_before_suspending
    @reactor.await_guard = -> { raise "guarded" }
    error = assert_raises(RuntimeError) { @reactor.call(timeout: 2) { @reactor.sleep(0.01) } }
    assert_equal "guarded", error.message
  end

  def test_await_outside_a_task_is_refused
    assert_raises(Sim800c::Error) { @reactor.await(Sim800c::Promise.new) }
  end

  def test_post_after_stop_is_ignored
    @reactor.stop
    refute @reactor.running?
    assert_nil @reactor.post { flunk "must not run" }
  end
end
