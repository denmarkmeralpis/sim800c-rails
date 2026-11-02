# frozen_string_literal: true

require "puma/plugin"

# Runs the sim800c runtime next to Puma: add `plugin :sim800c` to config/puma.rb.
#
# After Puma boots, the runtime is forked into its own process (so it holds the serial port once,
# however many Puma workers there are), restarted with backoff if it exits unexpectedly, and stopped
# with Puma. It exits by itself if Puma goes away.
Puma::Plugin.create do
  def start(launcher)
    @log_writer = launcher.log_writer
    @puma_pid = $$
    @runtime_pid = nil
    @stopping = false
    @lock = Mutex.new

    modern = Gem::Version.new(Puma::Const::VERSION) >= Gem::Version.new("7")
    events = launcher.events
    events.public_send(modern ? :after_booted : :on_booted) { start_runtime }
    events.public_send(modern ? :after_stopped : :on_stopped) { stop_runtime }
    events.public_send(modern ? :before_restart : :on_restart) { stop_runtime }
    in_background { supervise }
  end

  private

  def start_runtime
    @lock.synchronize do
      @stopping = false
      return if @runtime_pid || @starting

      @starting = true
    end
    pid = fork do
      Process.setproctitle("sim800c runtime (puma #{@puma_pid})")
      Thread.new { exit_when_puma_is_gone }
      # In cluster mode without preload_app!, Puma's master has not loaded the app.
      require File.expand_path("config/environment", Dir.pwd) unless defined?(Rails) && Rails.application&.initialized?
      Sim800c::Runtime.log_to_stdout!
      Rails.application.eager_load!
      Sim800c::Runtime.run!
    end
    @lock.synchronize do
      @runtime_pid = pid
      @starting = false
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    log "* sim800c runtime started (pid #{pid})"
  end

  def stop_runtime
    pid = @lock.synchronize do
      @stopping = true
      current = @runtime_pid
      @runtime_pid = nil
      current
    end
    return unless pid

    log "* Stopping the sim800c runtime (pid #{pid})"
    Process.kill(:TERM, pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    until Process.waitpid(pid, Process::WNOHANG)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill(:KILL, pid)
        Process.waitpid(pid)
        break
      end
      sleep 0.1
    end
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # Restarts a runtime that exited on its own (a crash), backing off up to 30 s.
  def supervise
    backoff = 1
    loop do
      sleep 1
      pid = @runtime_pid
      next unless pid

      exited = begin
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD
        pid
      end
      next unless exited

      status = $?
      @lock.synchronize { @runtime_pid = nil if @runtime_pid == pid }
      next if @stopping

      backoff = 1 if Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at > 60
      log "! sim800c runtime exited (#{status&.exitstatus || 'signal'}); restarting in #{backoff}s"
      sleep backoff
      backoff = [backoff * 2, 30].min
      start_runtime unless @stopping
    end
  end

  def exit_when_puma_is_gone
    loop do
      sleep 2
      next if Process.ppid == @puma_pid

      Process.kill(:TERM, Process.pid)
      break
    end
  end

  def log(message)
    @log_writer.log(message)
  end
end
