# frozen_string_literal: true

namespace :sim800c do
  desc "Run the SIM800C gateway runtime (owns the modem; run exactly one)"
  task run: :environment do
    Sim800c::Runtime.log_to_stdout!
    Rails.application.eager_load!
    Sim800c::Runtime.run!
  end

  desc "List the serial ports on this machine"
  task :ports do
    require "sim800c/core"
    ports = Sim800c::Transport::Serial.list
    if ports.empty?
      puts "No serial ports found. Is the SIM800C USB adapter plugged in (and its driver installed)?"
    else
      puts "Serial ports:\n\n"
      ports.each { |p| puts "  #{p[:path]}#{" -> #{p[:target]}" if p[:target]}" }
      puts "\nSet config.modem.serial_port (SIM800C_SERIAL_PORT) to one of these. On macOS use the /dev/cu.* device."
    end
  end

  desc "Set a dashboard user's password and sign out their sessions (creates an admin if missing)"
  task :reset_password, %i[username password] => :environment do |_t, args|
    username = args[:username].to_s
    password = args[:password].to_s
    abort 'Usage: bin/rails "sim800c:reset_password[username,new-password]"' if username.empty? || password.empty?

    begin
      user = Sim800c::User.find_by_username(username)
      if user
        user.update_account!(password: password, acting_user_id: nil)
        puts "Password for \"#{user.username}\" updated; existing sessions were signed out."
      else
        Sim800c::User.create_account!(username, password, "admin")
        puts "User \"#{username}\" did not exist and was created as an admin."
      end
    rescue Sim800c::AppError => e
      abort e.message
    end
  end
end
