# frozen_string_literal: true

require_relative "app"

run MockCas.new(users: YAML.load_file(File.expand_path("users.yml", __dir__)))
