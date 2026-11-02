# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.cache_store = :null_store
  config.action_dispatch.show_exceptions = :rescuable
  config.action_controller.allow_forgery_protection = false
  config.active_support.deprecation = :stderr
  # Tests read rows the runtime writes from another thread: no per-test query cache.
  config.active_support.executor_around_test_case = false
end
