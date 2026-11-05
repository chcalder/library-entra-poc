# frozen_string_literal: true

require_relative "boot"

require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "active_support/core_ext/numeric/bytes" # 64.megabytes below
require "active_support/core_ext/integer/time"  # 8.hours below

Bundler.require(*Rails.groups)

module LibraryPortal
  class Application < Rails::Application
    config.load_defaults 8.0
    config.autoload_lib(ignore: %w[tasks])

    # Server-side sessions: Entra tokens are too large (and too sensitive)
    # for the cookie store. memory_store suits one replica; use Redis
    # (config.cache_store = :redis_cache_store) when running more than one.
    config.cache_store = :memory_store, { size: 64.megabytes }
    config.session_store :cache_store, key: "_library_portal", expire_after: 8.hours,
                                       same_site: :lax, secure: Rails.env.production?

    config.logger = ActiveSupport::Logger.new($stdout).tap { |l| l.formatter = ::Logger::Formatter.new }
    config.filter_parameters += %i[token password ticket code client_secret]
  end
end
