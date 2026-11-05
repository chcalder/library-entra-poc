# frozen_string_literal: true

require_relative "boot"

require "rails"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

module PatronApi
  class Application < Rails::Application
    config.load_defaults 8.0
    config.api_only = true
    config.autoload_lib(ignore: %w[tasks])
    config.logger = ActiveSupport::Logger.new($stdout).tap { |l| l.formatter = ::Logger::Formatter.new }
    # ENTRA MIGRATION (phase 1): token, assertion and client_secret keep Entra credentials out of logs.
    config.filter_parameters += %i[token assertion client_secret password]
  end
end
