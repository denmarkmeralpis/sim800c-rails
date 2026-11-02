# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.cache_store = :memory_store
end
