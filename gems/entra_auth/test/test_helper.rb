# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "entra_auth"
require "minitest/autorun"

# Records requests and returns queued responses: [status, body_hash].
class FakeHttp
  attr_reader :posts, :gets

  def initialize(*responses)
    @responses = responses
    @posts = []
    @gets = []
  end

  def post_form(uri, form, headers: {})
    @posts << { uri: uri.to_s, form: form.transform_keys(&:to_s), headers: headers }
    @responses.shift || raise("FakeHttp: no response queued")
  end

  def get_json(uri, headers: {})
    @gets << { uri: uri.to_s, headers: headers }
    @responses.shift || raise("FakeHttp: no response queued")
  end
end

module TestConfig
  TENANT = "11111111-2222-3333-4444-555555555555"

  def self.build(**overrides)
    EntraAuth::Config.new(tenant_id: TENANT, client_id: "api-client-id",
                          client_secret: "s3cret", **overrides)
  end
end
