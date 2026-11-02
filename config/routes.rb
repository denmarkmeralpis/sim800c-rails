# frozen_string_literal: true

Sim800c::Engine.routes.draw do
  scope format: false do
    root to: "dashboard#show"
    get "healthz", to: "health#show"

    scope "api", module: "api" do
      scope "auth", controller: "auth" do
        post "login", action: :login
        get "setup", action: :setup_status
        post "setup", action: :setup
        post "logout", action: :logout
        get "me", action: :me
        post "password", action: :password
      end

      scope "v1" do
        get "status", to: "status#show"

        get "sms", to: "sms#index"
        post "sms", to: "sms#create"
        post "sms/read", to: "sms#read"
        post "sms/delete", to: "sms#bulk_delete"
        post "sms/retry-failed", to: "sms#retry_failed"
        get "sms/:id", to: "sms#show"
        delete "sms/:id", to: "sms#destroy"
        post "sms/:id/retry", to: "sms#retry_message"
        post "sms/:id/cancel", to: "sms#cancel"

        get "calls", to: "calls#index"
        post "calls", to: "calls#create"
        get "calls/active", to: "calls#active"
        post "calls/hangup", to: "calls#hangup"
        post "calls/answer", to: "calls#answer"
        post "calls/reject", to: "calls#reject"
        post "calls/dtmf", to: "calls#dtmf"
        post "calls/delete", to: "calls#bulk_delete"
        get "calls/:id", to: "calls#show"
        delete "calls/:id", to: "calls#destroy"

        get "ussd", to: "ussd#show"
        post "ussd", to: "ussd#create"
        post "ussd/reply", to: "ussd#reply"
        post "ussd/cancel", to: "ussd#cancel"
        get "ussd/sessions", to: "ussd#sessions"
        post "ussd/sessions/delete", to: "ussd#sessions_delete"
        get "ussd/sessions/:id", to: "ussd#session_show"
        delete "ussd/sessions/:id", to: "ussd#session_destroy"

        get "modem", to: "modem#show"
        get "modem/signal", to: "modem#signal"
        get "modem/events", to: "modem#events"
        post "modem/refresh", to: "modem#refresh"
        post "modem/reconnect", to: "modem#reconnect"
        post "modem/restart", to: "modem#restart"
        post "modem/at", to: "modem#at"
        get "modem/traffic", to: "modem#traffic"
        get "modem/ports", to: "modem#ports"

        get "admin/keys", to: "admin#keys"
        post "admin/keys", to: "admin#create_key"
        delete "admin/keys/:id", to: "admin#revoke_key"
        get "admin/users", to: "admin#users"
        post "admin/users", to: "admin#create_user"
        patch "admin/users/:id", to: "admin#update_user"
        delete "admin/users/:id", to: "admin#destroy_user"

        get "events", to: Sim800c::Web::EventStream

        get "simulator", to: "simulator#show"
        post "simulator/incoming-sms", to: "simulator#incoming_sms"
        post "simulator/incoming-call", to: "simulator#incoming_call"
        post "simulator/remote-hangup", to: "simulator#remote_hangup"
        post "simulator/signal", to: "simulator#signal"
        post "simulator/network", to: "simulator#network"
        post "simulator/sim", to: "simulator#sim"
        post "simulator/unplug", to: "simulator#unplug"
        post "simulator/freeze", to: "simulator#freeze_modem"
        post "simulator/reboot", to: "simulator#reboot"
      end

      match "*path", to: "fallback#not_found", via: :all
      match "/", to: "fallback#not_found", via: :all
    end
  end
end
