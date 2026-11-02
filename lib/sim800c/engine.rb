# frozen_string_literal: true

require "rails"
require_relative "web/assets"

module Sim800c
  class Engine < ::Rails::Engine
    isolate_namespace Sim800c

    PUBLIC_DIR = File.expand_path("../../public", __dir__)

    # The dashboard's static files (css, js, fonts), relative to the mount point.
    config.middleware.use Web::Assets, PUBLIC_DIR,
                          cache_control: ::Rails.env.production? ? "public, max-age=31536000, immutable" : "no-cache"

    # lib/tasks/sim800c.rake is loaded by Rails::Engine itself (paths["lib/tasks"]).
  end
end
