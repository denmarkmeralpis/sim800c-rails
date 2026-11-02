# frozen_string_literal: true

require "rails"

module Sim800c
  class Engine < ::Rails::Engine
    isolate_namespace Sim800c

    PUBLIC_DIR = File.expand_path("../../public", __dir__)

    # The dashboard's static files (css, js, fonts), served relative to the mount point.
    config.middleware.use ActionDispatch::Static, PUBLIC_DIR,
                          headers: {
                            "cache-control" => ::Rails.env.production? ? "public, max-age=3600" : "no-cache",
                            "x-content-type-options" => "nosniff"
                          }

    rake_tasks do
      load File.expand_path("../tasks/sim800c.rake", __dir__)
    end
  end
end
