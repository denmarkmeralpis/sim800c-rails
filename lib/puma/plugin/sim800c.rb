# frozen_string_literal: true

require "puma/plugin"

# Runs the sim800c runtime next to Puma: add `plugin :sim800c` to config/puma.rb.
#
# After Puma boots, `bin/rails sim800c:run` is started as a separate process (so the serial port is
# held once, however many Puma workers there are, and none of Puma's sockets are inherited), restarted
# with backoff if it exits unexpectedly, and stopped with Puma. It also exits by itself if Puma goes
# away. A phased restart does not restart it; restart Puma (or the runtime) to load new code into it.
Puma::Plugin.create do
  def start(launcher)
    @log_writer = launcher.log_writer
    @directory = launcher.options[:directory] || Dir.pwd
    @runtime_pid = nil
    @starting = false
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

  def command
    rails = File.join(@directory, "bin/rails")
    File.exist?(rails) ? [Gem.ruby, rails, "sim800c:run"] : [Gem.ruby, "-S", "rails", "sim800c:run"]
  end

  # Puma (re)booted: start the runtime. The supervisor passes `restart: true` and never revives a
  # runtime that is being stopped.
  def start_runtime(restart: false)
    @lock.synchronize do
      return if restart && @stopping

      @stopping = false
      return if @runtime_pid || @starting

      @starting = true
    end
    pid = Process.spawn({ "SIM800C_PARENT_PID" => Process.pid.to_s }, *command, chdir: @directory)
    @lock.synchronize do
      @runtime_pid = pid
      @starting = false
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    log "* sim800c runtime started (pid #{pid})"
  rescue SystemCallError => e
    @lock.synchronize { @starting = false }
    log "! Could not start the sim800c runtime: #{e.message}"
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

  # Restarts a runtime that exited on its own, backing off up to 30 s.
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
      start_runtime(restart: true)
    end
  end

  def log(message)
    @log_writer.log(message)
  end
end
