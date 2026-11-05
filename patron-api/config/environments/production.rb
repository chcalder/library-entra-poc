# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  # Internal-only ingress in Container Apps; other apps call it as http://<app-name>.
  config.hosts.clear
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  # API only: no cookies or sessions, so a per-boot key is fine when none is set.
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE") { SecureRandom.hex(64) }
end
