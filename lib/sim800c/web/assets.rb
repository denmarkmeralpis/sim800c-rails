# frozen_string_literal: true

module Sim800c
  module Web
    # Serves the dashboard's files from public/ under /static/<gem version>/ (relative to the mount
    # point). The version in the path changes on every release and is inherited by the scripts'
    # relative imports and the stylesheet's font URLs, so everything can be cached as immutable.
    class Assets
      PREFIX = "/static/#{VERSION}".freeze

      def initialize(app, root, cache_control: "public, max-age=31536000, immutable")
        @app = app
        @files = ActionDispatch::FileHandler.new(
          root, headers: { "cache-control" => cache_control, "x-content-type-options" => "nosniff" }
        )
      end

      def call(env)
        path = env["PATH_INFO"].to_s
        return @app.call(env) unless path.start_with?("#{PREFIX}/")
        return not_found unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

        @files.attempt(env.merge("PATH_INFO" => path.delete_prefix(PREFIX))) || not_found
      end

      private

      def not_found
        [404, { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-cache" }, ["Not found"]]
      end
    end
  end
end
