# frozen_string_literal: true

require_relative "test_helper"

class AuthenticatorTest < Minitest::Test
  STUDENT_CLAIMS = {
    "oid" => "oid-jstudent", "preferred_username" => "JStudent@contoso.edu", "name" => "Jordan Student",
    "scp" => "Patron.Read", "roles" => ["Student"], "azp" => "portal-client-id"
  }.freeze
  JOB_CLAIMS = { "oid" => "oid-job-sp", "roles" => ["Notices.Read.All"], "azp" => "job-client-id", "idtyp" => "app" }.freeze

  def authenticator(mode, store: demo_store)
    Authenticator.new(mode: mode, store: store, legacy_api_key: "legacy-key",
                      validator: FakeValidator.new("student-token" => STUDENT_CLAIMS, "job-token" => JOB_CLAIMS))
  end

  def test_legacy_mode_trusts_the_remote_user_header
    principal = authenticator("legacy").call("X-Api-Key" => "legacy-key", "X-Remote-User" => "jstudent")
    assert principal.legacy?
    assert_equal "jstudent", principal.netid
    assert_equal ["Student"], principal.roles, "legacy roles come from the patron record's affiliations"
  end

  def test_legacy_mode_rejects_bearer_tokens
    assert_raises(Authenticator::Unauthenticated) do
      authenticator("legacy").call("Authorization" => "Bearer student-token")
    end
  end

  def test_wrong_api_key
    assert_raises(Authenticator::Unauthenticated) { authenticator("both").call("X-Api-Key" => "nope") }
  end

  def test_both_mode_accepts_either_credential
    auth = authenticator("both")
    assert auth.call("X-Api-Key" => "legacy-key", "X-Remote-User" => "jstudent").legacy?
    assert auth.call("Authorization" => "Bearer student-token").delegated?
  end

  def test_entra_mode_retires_the_api_key
    error = assert_raises(Authenticator::Unauthenticated) do
      authenticator("entra").call("X-Api-Key" => "legacy-key", "X-Remote-User" => "jstudent")
    end
    assert_match(/no longer accepted/, error.message)
  end

  def test_delegated_token_maps_upn_to_netid_and_links_oid
    store = demo_store
    principal = authenticator("entra", store: store).call("Authorization" => "Bearer student-token")

    assert principal.delegated?
    assert_equal "jstudent", principal.netid
    assert principal.scope?("Patron.Read")
    assert_equal "student-token", principal.assertion, "the raw token is kept for the OBO exchange"
    assert_equal "oid-jstudent", store.profile("jstudent")[:entra_oid]
  end

  def test_app_only_token
    principal = authenticator("entra").call("Authorization" => "Bearer job-token")
    assert principal.app?
    assert_nil principal.netid
    assert principal.role?("Notices.Read.All")
  end

  def test_invalid_token_propagates
    assert_raises(EntraAuth::InvalidToken) { authenticator("entra").call("Authorization" => "Bearer forged") }
  end

  def test_missing_credentials
    assert_raises(Authenticator::Unauthenticated) { authenticator("both").call({}) }
  end

  def test_unknown_mode
    assert_raises(ArgumentError) { Authenticator.new(mode: "cas", store: demo_store) }
  end
end
