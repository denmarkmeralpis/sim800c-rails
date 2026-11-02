# frozen_string_literal: true

require "rails/generators"

module Sim800c
  module Generators
    # bin/rails generate sim800c:install [--mount-path=/sms-gateway]
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      class_option :mount_path, type: :string, default: "/sms-gateway", desc: "Where to mount the gateway"

      def create_initializer
        template "initializer.rb", "config/initializers/sim800c.rb"
      end

      def mount_engine
        route %(mount Sim800c::Engine => "#{options[:mount_path]}")
      end

      def copy_migrations
        rake "sim800c:install:migrations"
      end

      def show_next_steps
        say <<~TEXT

          sim800c-rails is installed. Next:

            1. bin/rails db:migrate
            2. Start the runtime (the one process that owns the modem), either
                 - add `plugin :sim800c` to config/puma.rb, or
                 - run `bin/rails sim800c:run` (e.g. a Procfile line: `sim800c: bin/rails sim800c:run`)
            3. Open #{options[:mount_path]} and create the admin account
               (or set SIM800C_ADMIN_PASSWORD before the first start).

          Without a modem, set SIM800C_MODEM_DRIVER=mock to use the built-in simulator.
        TEXT
      end
    end
  end
end
