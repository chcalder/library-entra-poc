# frozen_string_literal: true

# Framework-free tests for the portal's sign-in and API-client logic.
# Run: ruby portal/test/unit/portal_auth_test.rb
ROOT = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift File.join(ROOT, "../gems/entra_auth/lib")
require "minitest/autorun"
require "stringio"
require "entra_auth"
require File.join(ROOT, "lib/cas_client")
require File.join(ROOT, "lib/patron_api_client")
require File.join(ROOT, "app/models/identity")
require File.join(ROOT, "app/services/entra_token_store")
require File.join(ROOT, "app/models/token_correlation")
require File.join(ROOT, "../mock-cas/app")

class CasClientAgainstMockCasTest < Minitest::Test
  SERVICE = "http://localhost:3000/cas/callback"

  def setup
    @cas = MockCas.new(users: YAML.load_file(File.join(ROOT, "../mock-cas/users.yml")))
    # The portal's validation request is served in-process by the mock.
    http = lambda do |uri|
      _, _, body = @cas.call("REQUEST_METHOD" => "GET", "PATH_INFO" => uri.path, "QUERY_STRING" => uri.query)
      body.join
    end
    @client = CasClient.new(login_url: "http://localhost:8081/cas/login",
                            validate_url: "http://mock-cas:8081/cas/p3/serviceValidate",
                            logout_url: "http://localhost:8081/cas/logout", http: http)
  end

  def issue_ticket(user)
    form = URI.encode_www_form(username: user, password: "password", service: SERVICE)
    _, headers, = @cas.call("REQUEST_METHOD" => "POST", "PATH_INFO" => "/cas/login", "QUERY_STRING" => "",
                            "rack.input" => StringIO.new(form))
    URI.decode_www_form(URI(headers["location"]).query).to_h["ticket"]
  end

  def test_login_url_carries_the_service
    assert_equal "http://localhost:8081/cas/login?service=http%3A%2F%2Flocalhost%3A3000%2Fcas%2Fcallback",
                 @client.login_url(service: SERVICE)
  end

  def test_full_ticket_round_trip_and_attribute_mapping
    result = @client.validate(ticket: issue_ticket("llibrarian"), service: SERVICE)
    identity = Identity.from_cas(result)

    assert_equal "llibrarian", identity.netid
    assert_equal "Lee Librarian", identity.name
    assert_equal "llibrarian@example.edu", identity.email
    assert_includes identity.affiliations, "librarian"
    assert_nil identity.oid, "CAS has no immutable object ID; Entra adds one"
  end

  def test_replayed_ticket_fails
    ticket = issue_ticket("jstudent")
    @client.validate(ticket: ticket, service: SERVICE)
    error = assert_raises(CasClient::ValidationError) { @client.validate(ticket: ticket, service: SERVICE) }
    assert_match(/INVALID_TICKET/, error.message)
  end

  def test_missing_ticket
    assert_raises(CasClient::ValidationError) { @client.validate(ticket: nil, service: SERVICE) }
  end
end

class IdentityTest < Minitest::Test
  def test_from_entra_maps_upn_to_netid
    auth = { "uid" => "tid-oid", "info" => { "name" => "Jordan Student", "email" => "jstudent@contoso.edu" },
             "extra" => { "raw_info" => { "oid" => "oid-1", "preferred_username" => "JStudent@contoso.edu",
                                          "name" => "Jordan Student" } } }
    identity = Identity.from_entra(auth)
    assert_equal "jstudent", identity.netid
    assert_equal "oid-1", identity.oid
    assert_equal "entra", identity.source
    assert_equal identity, Identity.from_session(identity.to_session)
  end
end

class PatronApiClientTest < Minitest::Test
  Response = Struct.new(:code, :body, :headers) do
    def [](name) = headers[name]
  end

  def client(credentials, response)
    @sent = nil
    PatronApiClient.new(base_url: "http://patron-api:3001", credentials: credentials,
                        transport: ->(uri, req) { @sent = [uri, req]; response })
  end

  def test_legacy_credentials_send_api_key_and_remote_user
    api = client(PatronApiClient::LegacyCredentials.new("key", "jstudent"), Response.new("200", '{"loans":[]}', {}))
    api.loans
    assert_equal "http://patron-api:3001/api/v1/me/loans", @sent[0].to_s
    assert_equal "key", @sent[1]["X-Api-Key"]
    assert_equal "jstudent", @sent[1]["X-Remote-User"]
    assert_nil @sent[1]["Authorization"]
  end

  def test_bearer_credentials_ask_for_a_fresh_token_each_call
    calls = 0
    provider = -> { calls += 1; "token-#{calls}" }
    api = client(PatronApiClient::BearerCredentials.new(provider), Response.new("200", "{}", {}))
    api.me
    api.me
    assert_equal "Bearer token-2", @sent[1]["Authorization"]
    assert_nil @sent[1]["X-Remote-User"], "the user's identity now travels inside the token"
  end

  def test_claims_challenge_is_raised_for_step_up
    claims = EntraAuth::ClaimsChallenge.auth_context("c1")
    header = EntraAuth::ClaimsChallenge.header(claims)
    api = client(PatronApiClient::BearerCredentials.new(-> { "t" }),
                 Response.new("401", '{"message":"MFA required"}', { "WWW-Authenticate" => header }))
    error = assert_raises(PatronApiClient::ClaimsChallenge) { api.fines }
    assert_equal claims, error.claims
  end

  def test_unreachable_api_is_a_handled_error
    api = PatronApiClient.new(base_url: "http://127.0.0.1:9", credentials: PatronApiClient::LegacyCredentials.new("k", "x"))
    error = assert_raises(PatronApiClient::Error) { api.me }
    assert_equal 502, error.status
  end

  def test_error_mapping
    creds = PatronApiClient::LegacyCredentials.new("k", "x")
    assert_raises(PatronApiClient::Forbidden) { client(creds, Response.new("403", "{}", {})).eresources }
    assert_raises(PatronApiClient::NotAvailable) { client(creds, Response.new("501", "{}", {})).create_reminders }
    assert_raises(PatronApiClient::Unauthorized) { client(creds, Response.new("401", "{}", {})).me }
    assert_raises(PatronApiClient::DownstreamError) { client(creds, Response.new("502", "{}", {})).create_reminders }
  end

  def test_graph_profile_calls_the_obo_check_endpoint
    api = client(PatronApiClient::BearerCredentials.new(-> { "t" }), Response.new("200", '{"same_user":true}', {}))
    assert api.graph_profile["same_user"]
    assert_equal "http://patron-api:3001/api/v1/me/graph-profile", @sent[0].to_s
  end

  def test_access_token_is_read_back_from_the_api_not_decoded_by_the_portal
    api = client(PatronApiClient::BearerCredentials.new(-> { "t" }), Response.new("200", '{"claims":{"aud":"api"}}', {}))
    assert_equal "api", api.access_token_seen_by_api.dig("claims", "aud")
    assert_equal "http://patron-api:3001/api/v1/me/token", @sent[0].to_s
    assert_equal "Bearer t", @sent[1]["Authorization"]
  end
end

class EntraTokenStoreTest < Minitest::Test
  class FakeRefresh
    attr_reader :calls

    def initialize(result) = (@result = result) && (@calls = 0)

    def refresh(refresh_token:, scope:)
      @calls += 1
      raise @result if @result.is_a?(Exception)

      @result
    end
  end

  def test_returns_the_stored_token_until_near_expiry_then_refreshes
    now = Time.at(1_000_000)
    session = {}
    refreshed = EntraAuth::Token.new(access_token: "new-at", refresh_token: "new-rt", expires_at: now + 7200)
    refresh = FakeRefresh.new(refreshed)
    store = EntraTokenStore.new(session, refresh_client: refresh, scope: "api://p/Patron.Read offline_access",
                                         clock: -> { now })

    store.store("token" => "at-1", "refresh_token" => "rt-1", "expires_at" => now.to_i + 3600)
    assert_equal "at-1", store.access_token
    assert_equal 0, refresh.calls

    now += 3570
    assert_equal "new-at", store.access_token
    assert_equal "new-rt", session["entra_tokens"]["refresh_token"]
  end

  def test_conditional_access_on_refresh_becomes_a_step_up
    now = Time.at(1_000_000)
    refresh = FakeRefresh.new(EntraAuth::ClaimsChallengeRequired.new('{"access_token":{"acrs":{"essential":true,"value":"c1"}}}'))
    store = EntraTokenStore.new({}, refresh_client: refresh, scope: "s", clock: -> { now })
    store.store("token" => "at", "refresh_token" => "rt", "expires_at" => now.to_i - 1)
    assert_raises(PatronApiClient::ClaimsChallenge) { store.access_token }
  end

  def test_failed_refresh_ends_the_session
    now = Time.at(1_000_000)
    refresh = FakeRefresh.new(EntraAuth::TokenError.new("invalid_grant", "AADSTS70043: refresh token expired"))
    store = EntraTokenStore.new({}, refresh_client: refresh, scope: "s", clock: -> { now })
    store.store("token" => "at", "refresh_token" => "rt", "expires_at" => now.to_i - 1)
    assert_raises(EntraTokenStore::SessionExpired) { store.access_token }
  end
end

class TokenCorrelationTest < Minitest::Test
  ID = { "oid" => "u1", "tid" => "t1", "preferred_username" => "js@contoso.edu", "aud" => "portal", "sub" => "s-portal" }.freeze
  API = { "oid" => "u1", "tid" => "t1", "preferred_username" => "js@contoso.edu", "aud" => "patron-api",
          "azp" => "portal", "scp" => "Patron.Read", "sub" => "s-api" }.freeze
  # Graph tokens are v1: upn and appid instead of preferred_username and azp.
  OBO = { "oid" => "u1", "tid" => "t1", "upn" => "js@contoso.edu", "aud" => "https://graph.microsoft.com",
          "appid" => "patron-api", "scp" => "User.Read", "sub" => "s-graph" }.freeze
  GRAPH = { "id" => "u1", "user_principal_name" => "js@contoso.edu" }.freeze

  def row(correlation, claim) = correlation.rows.find { |r| r.claim == claim }

  def test_the_user_is_the_same_across_every_hop
    c = TokenCorrelation.new(id_token: ID, access_token: API, obo_token: OBO, graph_user: GRAPH)
    assert_equal %w[u1 u1 u1 u1], row(c, "oid").values
    assert row(c, "oid").consistent?
    assert row(c, "preferred_username / upn").consistent?
    assert_equal ["portal", "patron-api", "https://graph.microsoft.com", nil], row(c, "aud").values
    assert_equal [nil, "portal", "patron-api", nil], row(c, "azp / appid").values, "OBO token is held by the API"
    assert_empty c.missing_sources
  end

  def test_a_different_user_is_flagged_and_missing_tokens_are_listed
    c = TokenCorrelation.new(id_token: nil, access_token: API, obo_token: OBO.merge("oid" => "u2"), graph_user: GRAPH)
    refute row(c, "oid").consistent?
    assert_equal ["ID token (portal)"], c.missing_sources
  end
end
