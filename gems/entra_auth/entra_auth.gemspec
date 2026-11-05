# frozen_string_literal: true

require_relative "lib/entra_auth/version"

Gem::Specification.new do |spec|
  spec.name = "entra_auth"
  spec.version = EntraAuth::VERSION
  spec.summary = "Microsoft Entra token helpers for Rails apps: OBO, client credentials, refresh, validation"
  spec.authors = ["Library Entra POC"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "jwt", ">= 2.7", "< 4"
end
