# frozen_string_literal: true

module Sim800c
  module Api
    # Test controls for the built-in SIM800C simulator (config.modem.driver = :mock only).
    class SimulatorController < ApiController
      SENDER = { min: 2, max: 20 }.freeze

      before_action :require_simulator
      before_action :authenticate!
      before_action(except: :show) { require_scope!("modem:write") }

      def show
        require_scope!("modem:read")
        respond("simulator.snapshot")
      end

      def incoming_sms
        v = body_validation
        args = { from: v.string("from", trim: true, **SENDER), message: v.string("message", min: 1, max: 2000) }
        v.validate!
        respond("simulator.incoming_sms", args, status: :accepted)
      end

      def incoming_call
        v = body_validation
        args = { from: v.string("from", trim: true, **SENDER) }
        v.validate!
        respond("simulator.incoming_call", args, status: :accepted)
      end

      def remote_hangup = respond("simulator.remote_hangup")

      def signal
        v = body_validation
        args = { rssi: v.integer("rssi", min: 0, max: 31) }
        v.validate!
        respond("simulator.signal", args)
      end

      def network
        v = body_validation
        args = { registration: v.integer("registration", min: 0, max: 5) }
        v.validate!
        respond("simulator.network", args)
      end

      def sim
        v = body_validation
        args = { inserted: v.boolean("inserted") }
        v.validate!
        respond("simulator.sim", args)
      end

      def unplug
        v = body_validation
        args = { seconds: v.number("seconds", min: 1, max: 600, default: 10) }
        v.validate!
        respond("simulator.unplug", args)
      end

      def freeze_modem
        v = body_validation
        args = { seconds: v.number("seconds", min: 1, max: 600, default: 30) }
        v.validate!
        respond("simulator.freeze", args)
      end

      def reboot = respond("simulator.reboot")

      private

      def respond(op, args = {}, status: :ok)
        render json: { data: Gateway.request(op, args) }, status: status
      end

      # Like sms-gateway, the simulator routes only exist with the mock driver.
      def require_simulator
        return if Sim800c.config.modem.driver == :mock

        render_error(404, "not_found", "No route for #{request.request_method} #{request.path_info}")
      end
    end
  end
end
