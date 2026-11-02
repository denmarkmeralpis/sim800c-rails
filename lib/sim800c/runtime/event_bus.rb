# frozen_string_literal: true

module Sim800c
  class Runtime
    # Application-wide events, consumed by the event stream (RPC subscribers), webhooks and services.
    # Payloads are API-shaped Hashes.
    #
    #   modem.status   sms.received  sms.updated (any change)  sms.status (delivery status changed)
    #   sms.deleted {ids}  call.updated  call.incoming  call.ended  call.deleted {ids}
    #   ussd.updated  ussd.ended (once, when completed / cancelled / failed)  log.entry
    class EventBus
      include Emitter

      NAMES = %w[
        modem.status sms.received sms.updated sms.status sms.deleted call.updated call.incoming call.ended
        call.deleted ussd.updated ussd.ended log.entry
      ].freeze
    end
  end
end
