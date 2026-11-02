# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "dummy-secret-key-base-for-tests-only-#{'x' * 64}"
    config.active_record.maintain_test_schema = false
    config.logger = ActiveSupport::Logger.new(File.expand_path("../log/#{Rails.env}.log", __dir__))
    config.log_level = :warn
  end
end
