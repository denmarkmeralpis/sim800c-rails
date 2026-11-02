# frozen_string_literal: true

module Sim800c
  module Api
    class StatusController < ApiController
      before_action :authenticate!

      def show
        require_scope!("modem:read")
        snapshot = Gateway.snapshot
        calls = principal.scope?("calls:read")
        render json: {
          modem: snapshot["modem"],
          canOperate: snapshot["canOperate"],
          reason: snapshot["reason"],
          call: calls ? snapshot["call"] : nil,
          sms: principal.scope?("sms:read") ? SmsMessage.stats : nil,
          calls: calls ? Call.stats : nil,
          simulator: snapshot["simulator"]
        }
      end
    end
  end
end
