# frozen_string_literal: true

# Framework-free tests for the API's auth and integration logic.
# Run: ruby -Itest/unit -e 'Dir["test/unit/*_test.rb"].each { |f| require File.expand_path(f) }'
ROOT = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift File.join(ROOT, "../gems/entra_auth/lib")
$LOAD_PATH.unshift File.join(ROOT, "lib")

require "minitest/autorun"
require "entra_auth"
require File.join(ROOT, "app/models/patron_store")
require File.join(ROOT, "app/models/principal")
require File.join(ROOT, "app/services/authenticator")
require File.join(ROOT, "app/services/graph_http")
require File.join(ROOT, "app/services/graph_calendar")
require File.join(ROOT, "app/services/graph_profile")
require "overdue_notices_job"

def demo_store(today: Date.new(2026, 11, 4))
  PatronStore.load(File.join(ROOT, "data/patrons.yml"), today: today)
end

# Stands in for EntraAuth::TokenValidator: returns canned claims per token.
class FakeValidator
  def initialize(tokens) = @tokens = tokens

  def validate(token)
    @tokens.fetch(token) { raise EntraAuth::InvalidToken, "bad signature" }
  end
end
