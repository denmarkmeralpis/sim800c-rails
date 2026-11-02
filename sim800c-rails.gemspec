# frozen_string_literal: true

require_relative "lib/sim800c/version"

Gem::Specification.new do |spec|
  spec.name = "sim800c-rails"
  spec.version = Sim800c::VERSION
  spec.authors = ["Den Meralpis"]
  spec.email = ["denmarkmeralpis@gmail.com"]

  spec.summary = "SMS, voice call and USSD gateway for the SIMCom SIM800C, as a mountable Rails engine."
  spec.description = <<~DESC
    Drives a SIMCom SIM800C GSM modem (serial, TCP bridge or built-in simulator) from a Rails app:
    queued SMS with retries and delivery reports, multipart and Unicode messages, a real-time inbox,
    voice call control and history, USSD sessions, modem monitoring with automatic reconnect,
    a REST API with scoped API keys, Server-Sent Events, signed webhooks and a web dashboard.
  DESC
  spec.homepage = "https://github.com/denmarkmeralpis/sim800c-rails"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["{app,config,db,lib,public,exe}/**/*", "README.md", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["sim800c-bridge"]
  spec.require_paths = ["lib"]

  spec.add_dependency "actionpack", ">= 7.2"
  spec.add_dependency "activerecord", ">= 7.2"
  spec.add_dependency "activesupport", ">= 7.2"
  spec.add_dependency "railties", ">= 7.2"
end
