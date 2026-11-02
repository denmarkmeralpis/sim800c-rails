# frozen_string_literal: true

Rails.application.routes.draw do
  mount Sim800c::Engine => "/sms-gateway"
end
