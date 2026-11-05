# frozen_string_literal: true

require_relative "test_helper"
require "openssl"

class ClaimsChallengeTest < Minitest::Test
  def test_header_round_trip
    claims = EntraAuth::ClaimsChallenge.auth_context("c1")
    header = EntraAuth::ClaimsChallenge.header(claims)

    assert_includes header, 'error="insufficient_claims"'
    assert_equal claims, EntraAuth::ClaimsChallenge.parse(header)
    assert_equal({ "access_token" => { "acrs" => { "essential" => true, "value" => "c1" } } }, JSON.parse(claims))
  end

  def test_parse_returns_nil_without_a_challenge
    assert_nil EntraAuth::ClaimsChallenge.parse('Bearer error="invalid_token"')
    assert_nil EntraAuth::ClaimsChallenge.parse(nil)
  end
end

class JwksProviderTest < Minitest::Test
  def test_caches_and_limits_forced_refreshes
    now = Time.at(1_000_000)
    keys = [200, { "keys" => [{ "kid" => "k1" }] }]
    http = FakeHttp.new(keys, keys)
    provider = EntraAuth::JwksProvider.new(TestConfig.build, http: http, clock: -> { now })

    provider.keys
    provider.keys(force: true) # too soon after the last fetch
    assert_equal 1, http.gets.size

    now += 301
    provider.keys(force: true)
    assert_equal 2, http.gets.size
  end
end

# Runs only where the `jwt` gem is installed (bundle install in the app).
class TokenValidatorTest < Minitest::Test
  def setup
    require "jwt"
  rescue LoadError
    skip "jwt gem not installed; run inside a bundled app to exercise TokenValidator"
  end

  def key
    @key ||= OpenSSL::PKey::RSA.generate(2048)
  end

  def jwk
    @jwk ||= JWT::JWK.new(key, kid: "test-kid")
  end

  def validator(config = TestConfig.build)
    jwks = Struct.new(:set) { def keys(force: false) = set }.new({ keys: [jwk.export] })
    EntraAuth::TokenValidator.new(config, jwks: jwks)
  end

  def token(overrides = {})
    claims = {
      "aud" => "api-client-id",
      "iss" => "https://login.microsoftonline.com/#{TestConfig::TENANT}/v2.0",
      "tid" => TestConfig::TENANT,
      "oid" => "oid-1",
      "scp" => "Patron.Read",
      "iat" => Time.now.to_i,
      "nbf" => Time.now.to_i,
      "exp" => Time.now.to_i + 3600
    }.merge(overrides)
    JWT.encode(claims, key, "RS256", kid: "test-kid")
  end

  def test_accepts_a_valid_token
    assert_equal "oid-1", validator.validate(token)["oid"]
  end

  def test_rejects_wrong_audience
    assert_raises(EntraAuth::InvalidToken) { validator.validate(token("aud" => "https://graph.microsoft.com")) }
  end

  def test_rejects_v1_issuer
    assert_raises(EntraAuth::InvalidToken) do
      validator.validate(token("iss" => "https://sts.windows.net/#{TestConfig::TENANT}/"))
    end
  end

  def test_rejects_expired
    assert_raises(EntraAuth::InvalidToken) { validator.validate(token("exp" => Time.now.to_i - 3600)) }
  end

  def test_rejects_other_tenant
    assert_raises(EntraAuth::InvalidToken) { validator.validate(token("tid" => "someone-else")) }
  end

  def test_rejects_unsigned_algorithm
    unsigned = JWT.encode({ "aud" => "api-client-id" }, nil, "none")
    assert_raises(EntraAuth::InvalidToken) { validator.validate(unsigned) }
  end
end
