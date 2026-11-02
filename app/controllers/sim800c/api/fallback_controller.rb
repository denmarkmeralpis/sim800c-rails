# frozen_string_literal: true

module Sim800c
  module Api
    class FallbackController < ApiController
      def not_found
        render_error(404, "not_found", "No route for #{request.request_method} #{request.path_info}")
      end
    end
  end
end
