# frozen_string_literal: true

module Sim800c
  # Liveness probe: answers 200 while the web app runs, even with the modem or runtime down.
  class HealthController < ActionController::API
    def show
      modem = begin
        Gateway.client.request("health", {}, timeout: 1)["modem"]
      rescue StandardError
        nil
      end
      render json: { ok: true, modem: modem || "disconnected", runtime: modem ? "running" : "offline" }
    end
  end
end
