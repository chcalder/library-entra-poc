# frozen_string_literal: true

require_relative "test_helper"

class TokenFlowsTest < Minitest::Test
  OK = [200, { "access_token" => "downstream-token", "expires_in" => 3600, "token_type" => "Bearer" }].freeze

  def test_obo_sends_the_jwt_bearer_grant_with_the_incoming_token
    http = FakeHttp.new(OK)
    config = TestConfig.build
    obo = EntraAuth::OboClient.new(config, endpoint: EntraAuth::TokenEndpoint.new(config, http: http))

    token = obo.acquire(user_assertion: "incoming-access-token",
                        scope: "https://graph.microsoft.com/.default", user_key: "oid-1")

    assert_equal "downstream-token", token.access_token
    post = http.posts.first
    assert_equal "https://login.microsoftonline.com/#{TestConfig::TENANT}/oauth2/v2.0/token", post[:uri]
    assert_equal "urn:ietf:params:oauth:grant-type:jwt-bearer", post[:form]["grant_type"]
    assert_equal "on_behalf_of", post[:form]["requested_token_use"]
    assert_equal "incoming-access-token", post[:form]["assertion"]
    assert_equal "api-client-id", post[:form]["client_id"]
    assert_equal "s3cret", post[:form]["client_secret"]
  end

  def test_obo_caches_per_user_and_scope
    http = FakeHttp.new(OK, OK)
    config = TestConfig.build
    obo = EntraAuth::OboClient.new(config, endpoint: EntraAuth::TokenEndpoint.new(config, http: http))

    2.times { obo.acquire(user_assertion: "a", scope: "s/.default", user_key: "oid-1") }
    assert_equal 1, http.posts.size, "same user + scope should hit the cache"

    obo.acquire(user_assertion: "b", scope: "s/.default", user_key: "oid-2")
    assert_equal 2, http.posts.size, "a different user must never reuse another user's token"
  end

  def test_obo_requires_a_user_key
    obo = EntraAuth::OboClient.new(TestConfig.build, endpoint: Object.new)
    assert_raises(ArgumentError) { obo.acquire(user_assertion: "a", scope: "s/.default", user_key: nil) }
  end

  def test_conditional_access_becomes_a_claims_challenge
    claims = '{"access_token":{"capolids":{"essential":true,"values":["abc"]}}}'
    http = FakeHttp.new([400, { "error" => "interaction_required",
                                "error_description" => "AADSTS50079: MFA required", "claims" => claims }])
    config = TestConfig.build
    obo = EntraAuth::OboClient.new(config, endpoint: EntraAuth::TokenEndpoint.new(config, http: http))

    error = assert_raises(EntraAuth::ClaimsChallengeRequired) do
      obo.acquire(user_assertion: "a", scope: "s/.default", user_key: "oid-1")
    end
    assert_equal claims, error.claims
  end

  def test_consent_errors_are_recognisable
    http = FakeHttp.new([400, { "error" => "invalid_grant",
                                "error_description" => "AADSTS65001: The user or administrator has not consented" }])
    config = TestConfig.build
    endpoint = EntraAuth::TokenEndpoint.new(config, http: http)

    error = assert_raises(EntraAuth::TokenError) { endpoint.request(grant_type: "x") }
    assert error.consent_required?
  end

  def test_client_credentials_requires_dot_default_and_caches
    http = FakeHttp.new(OK)
    config = TestConfig.build(client_id: "job-client-id")
    cc = EntraAuth::ClientCredentialsClient.new(config, endpoint: EntraAuth::TokenEndpoint.new(config, http: http))

    assert_raises(ArgumentError) { cc.acquire(scope: "api://patron/Patron.Read") }

    2.times { cc.acquire(scope: "api://patron/.default") }
    assert_equal 1, http.posts.size
    assert_equal "client_credentials", http.posts.first[:form]["grant_type"]
    assert_equal "api://patron/.default", http.posts.first[:form]["scope"]
  end

  def test_refresh
    http = FakeHttp.new([200, OK[1].merge("refresh_token" => "new-rt")])
    config = TestConfig.build
    client = EntraAuth::RefreshClient.new(config, endpoint: EntraAuth::TokenEndpoint.new(config, http: http))

    token = client.refresh(refresh_token: "old-rt", scope: "api://patron/Patron.Read offline_access")
    assert_equal "new-rt", token.refresh_token
    assert_equal "refresh_token", http.posts.first[:form]["grant_type"]
  end

  def test_client_assertion_replaces_secret
    http = FakeHttp.new(OK)
    config = TestConfig.build(client_secret: nil, client_assertion: -> { "mi-assertion" })
    EntraAuth::TokenEndpoint.new(config, http: http).request(grant_type: "client_credentials", scope: "x/.default")

    form = http.posts.first[:form]
    assert_equal "mi-assertion", form["client_assertion"]
    assert_equal "urn:ietf:params:oauth:client-assertion-type:jwt-bearer", form["client_assertion_type"]
    refute form.key?("client_secret")
  end

  def test_managed_identity_assertion_reads_the_container_apps_endpoint
    http = FakeHttp.new([200, { "access_token" => "mi-token", "expires_on" => (Time.now.to_i + 3600).to_s }])
    env = { "IDENTITY_ENDPOINT" => "http://localhost:42356/msi/token", "IDENTITY_HEADER" => "hdr" }
    assertion = EntraAuth::ManagedIdentityAssertion.new(managed_identity_client_id: "mi-client", env: env, http: http)

    assert_equal "mi-token", assertion.call
    assert_equal "mi-token", assertion.call # cached
    assert_equal 1, http.gets.size
    assert_includes http.gets.first[:uri], "resource=api%3A%2F%2FAzureADTokenExchange"
    assert_equal "hdr", http.gets.first[:headers]["X-IDENTITY-HEADER"]
  end

  def test_token_cache_expires_with_skew
    now = Time.at(1_000_000)
    cache = EntraAuth::TokenCache.new(skew: 300, clock: -> { now })
    short = EntraAuth::Token.new(access_token: "a", expires_at: now + 200)
    long = EntraAuth::Token.new(access_token: "b", expires_at: now + 3600)

    assert_equal "a", cache.fetch("k") { short }.access_token
    assert_equal "b", cache.fetch("k") { long }.access_token, "token inside the skew window must be replaced"
    assert_equal "b", cache.fetch("k") { flunk "should be cached" }.access_token
  end
end
