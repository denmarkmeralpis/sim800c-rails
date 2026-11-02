# frozen_string_literal: true

require_relative "promise"

module Sim800c
  # Single-threaded event loop that runs the gateway's state machines, in the spirit of Node's
  # event loop. All runtime state is owned by the reactor thread:
  #
  # * work is posted as jobs (`post`) or timers (`after`, `every`) and each unit runs in its own
  #   Fiber (`task`, `go`);
  # * `await(promise)` suspends the current fiber until the promise settles, letting other work
  #   run meanwhile — the only points where state may change under a running task;
  # * no Fiber scheduler is installed, so blocking calls (database queries) block the loop, and a
  #   fiber can never be suspended in the middle of one;
  # * other threads hand bytes or requests over with `post` or `call`.
  class Reactor
    STOP = Object.new.freeze
    private_constant :STOP

    class Timer
      attr_reader :deadline, :seq, :interval, :block

      def initialize(deadline, seq, interval, block)
        @deadline = deadline
        @seq = seq
        @interval = interval
        @block = block
        @cancelled = false
      end

      def cancel
        @cancelled = true
        nil
      end

      def cancelled? = @cancelled

      def <=>(other) = [deadline, seq] <=> [other.deadline, other.seq]

      def reschedule(now) # :nodoc:
        @deadline += @interval
        @deadline = now + @interval if @deadline < now
      end
    end

    attr_reader :name, :thread
    # Called after each job on the reactor thread (the runtime uses it to release database leases).
    attr_accessor :after_job
    # Called before a task suspends in #await (the runtime uses it to refuse awaiting inside a transaction).
    attr_accessor :await_guard

    def initialize(name: "sim800c-reactor", logger: Sim800c.logger)
      @name = name
      @logger = logger
      @jobs = Thread::Queue.new
      @timers = []
      @seq = 0
      @thread = nil
      @root_fiber = nil
    end

    def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def now = self.class.now

    def start
      raise Error, "reactor already started" if @thread

      ready = Thread::Queue.new
      @thread = Thread.new do
        Thread.current.name = @name
        Thread.current.report_on_exception = true
        @root_fiber = Fiber.current
        ready << true
        run
      end
      ready.pop
      self
    end

    def running? = @thread&.alive? || false

    def on_thread? = Thread.current.equal?(@thread)

    # True inside a task fiber on the reactor thread, where #await may be used.
    def in_task? = on_thread? && !Fiber.current.equal?(@root_fiber)

    # Queues a block to run on the reactor thread. Safe from any thread; ignored after #stop.
    def post(&block)
      @jobs.push(block)
      nil
    rescue ClosedQueueError
      nil
    end

    # Starts a fiber for the block right away (like calling an async function: it runs until its
    # first #await). Returns a Promise of the block's result. Reactor thread only.
    def task(&block)
      assert_reactor!
      promise = Promise.new
      fiber = Fiber.new(blocking: true) do
        promise.resolve(block.call)
      rescue Exception => e # rubocop:disable Lint/RescueException -- surfaced to whoever awaits the task
        promise.reject(e)
      end
      fiber.resume
      promise
    end

    # Fire-and-forget task; failures are logged. Callable from any thread.
    def go(label = nil, &block)
      return post { go(label, &block) } unless on_thread?

      task(&block).on_settle do |p|
        log_failure(label || "task", p.reason) if p.rejected?
      end
      nil
    end

    # Suspends the current task until the promise settles; returns its value or raises its error.
    def await(promise)
      return promise.value! if promise.settled?
      raise Error, "await can only be used inside a reactor task" unless in_task?

      await_guard&.call
      fiber = Fiber.current
      promise.on_settle { post { fiber.resume } }
      Fiber.yield
      promise.value!
    end

    def sleep(seconds)
      promise = Promise.new
      after(seconds) { promise.resolve }
      await(promise)
    end

    # Runs the block (in a task) once, after `seconds`. Returns a Timer that can be cancelled.
    def after(seconds, &block)
      schedule(seconds, nil, block)
    end

    # Runs the block (in a task) every `seconds`. Returns a Timer that can be cancelled.
    def every(seconds, &block)
      schedule(seconds, seconds, block)
    end

    # Runs blocking work on a helper thread; the returned promise settles on the reactor thread.
    def defer(&block)
      assert_reactor!
      promise = Promise.new
      Thread.new do
        Thread.current.name = "#{@name}-defer"
        Thread.current.report_on_exception = false
        result = block.call
        post { promise.resolve(result) }
      rescue Exception => e # rubocop:disable Lint/RescueException -- handed back to the awaiting task
        post { promise.reject(e) }
      end
      promise
    end

    # Runs the block in a task on the reactor and waits for its result. For other threads (inside a
    # task it simply awaits). Raises Sim800c::TimeoutError if `timeout` seconds pass first.
    def call(timeout: nil, &block)
      return await(task(&block)) if in_task?
      raise Error, "Reactor#call would deadlock on the reactor thread" if on_thread?
      raise Error, "reactor is not running" unless running?

      result = Thread::Queue.new
      post { task(&block).on_settle { |p| result.push(p) } }
      promise = result.pop(timeout: timeout)
      raise TimeoutError, "reactor did not answer within #{timeout}s" if promise.nil?

      promise.value!
    end

    # Stops the loop after the jobs already queued. Pending timers and suspended tasks are dropped.
    def stop(timeout: 5)
      thread = @thread
      return unless thread

      if on_thread?
        @jobs.push(STOP)
        return
      end
      @jobs.push(STOP) unless @jobs.closed?
      thread.join(timeout)
      @jobs.close
      thread.kill if thread.alive?
      nil
    end

    private

    def run
      loop do
        job = @jobs.pop(timeout: wait_time)
        fire_timers
        next if job.nil?
        break if job.equal?(STOP)

        run_job(job)
      end
    ensure
      @jobs.close
      @timers.clear
    end

    def run_job(job)
      job.call
    rescue StandardError, ScriptError => e
      log_failure("job", e)
    ensure
      begin
        after_job&.call
      rescue StandardError => e
        log_failure("after_job hook", e)
      end
    end

    def wait_time
      first = @timers.first
      return nil unless first

      [first.deadline - now, 0].max
    end

    def fire_timers
      return if @timers.empty?

      t = now
      due = []
      due << @timers.shift while (first = @timers.first) && first.deadline <= t
      due.each do |timer|
        next if timer.cancelled?

        if timer.interval
          timer.reschedule(t)
          insert_timer(timer)
        end
        go("timer", &timer.block)
      end
    end

    def schedule(seconds, interval, block)
      raise ArgumentError, "block required" unless block

      delay = [seconds.to_f, 0.0].max
      timer = Timer.new(now + delay, (@seq += 1), interval && [interval.to_f, 0.001].max, block)
      if on_thread?
        insert_timer(timer)
      else
        post { insert_timer(timer) }
      end
      timer
    end

    def insert_timer(timer)
      idx = @timers.bsearch_index { |t| (t <=> timer) >= 0 } || @timers.size
      @timers.insert(idx, timer)
    end

    def assert_reactor!
      raise Error, "must be called on the reactor thread" unless on_thread?
    end

    def log_failure(what, error)
      @logger.error("[sim800c] Unhandled error in reactor #{what}: #{error.class}: #{error.message}\n" \
                    "#{error.backtrace&.first(12)&.join("\n")}")
    end
  end
end
