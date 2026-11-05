# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  # Container Apps terminates TLS at its ingress and forwards plain HTTP.
  config.assume_ssl = true
  config.force_ssl = true
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/healthz" } } }
  config.hosts.clear
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE")
end
