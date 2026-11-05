# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class PatronStoreTest < Minitest::Test
  def test_affiliations_map_to_roles
    store = demo_store
    assert_equal ["Student"], store.roles_for("jstudent")
    assert_equal %w[Staff Librarian], store.roles_for("llibrarian")
    assert_equal ["Alumni"], store.roles_for("aalumni")
  end

  def test_oid_crosswalk_refuses_a_second_account_for_the_same_netid
    store = demo_store
    store.link_oid("jstudent", "oid-1")
    store.link_oid("jstudent", "oid-1") # idempotent
    assert_equal "jstudent", store.find_by_oid("oid-1")[:netid]
    assert_raises(PatronStore::NotFound) { store.link_oid("jstudent", "oid-2") }
  end

  def test_overdue_and_waive
    store = demo_store
    assert_equal %w[L-1003 L-4001], store.overdue_loans.map { |l| l[:id] }.sort
    assert_equal "waived", store.waive_fine!("jstudent", "F-501")[:status]
  end
end

class GraphCalendarTest < Minitest::Test
  LOAN = { id: "L-1001", title: "Designing Data-Intensive Applications", due_date: "2026-11-09" }.freeze

  def test_creates_an_idempotent_event_with_the_obo_token
    seen = nil
    transport = lambda do |method, url, token, payload|
      seen = { method: method, url: url, token: token, payload: payload }
      [201, {}, '{"id":"evt-1"}']
    end
    event = GraphCalendar.new(time_zone: "Pacific Standard Time", transport: transport)
                         .create_due_date_reminder("graph-token", LOAN)

    assert_equal "evt-1", event["id"]
    assert_equal "https://graph.microsoft.com/v1.0/me/events", seen[:url]
    assert_equal "graph-token", seen[:token]
    assert_equal "2026-11-09T09:00:00", seen[:payload][:start][:dateTime]
    assert_equal "library-loan-L-1001-2026-11-09", seen[:payload][:transactionId]
  end

  def test_graph_claims_challenge_is_passed_up
    header = EntraAuth::ClaimsChallenge.header('{"access_token":{"nbf":{"essential":true,"value":"1"}}}')
    transport = ->(*) { [401, { "www-authenticate" => header }, ""] }
    assert_raises(EntraAuth::ClaimsChallengeRequired) do
      GraphCalendar.new(transport: transport).create_due_date_reminder("t", LOAN)
    end
  end

  def test_no_mailbox_is_a_readable_graph_error
    body = '{"error":{"code":"MailboxNotEnabledForRESTAPI","message":"The mailbox is either inactive, soft-deleted, or is hosted on-premise."}}'
    error = assert_raises(GraphHttp::Error) do
      GraphCalendar.new(transport: ->(*) { [404, {}, body] }).create_due_date_reminder("t", LOAN)
    end
    assert_equal "MailboxNotEnabledForRESTAPI", error.code
    assert_match(/no Exchange Online mailbox/, error.user_message)
    assert_match(/404 MailboxNotEnabledForRESTAPI: The mailbox/, error.message)
  end

  def test_unexpected_graph_error_without_a_json_body
    error = assert_raises(GraphHttp::Error) do
      GraphCalendar.new(transport: ->(*) { [503, {}, "Service Unavailable"] }).create_due_date_reminder("t", LOAN)
    end
    assert_nil error.code
    assert_equal "Microsoft Graph refused the request (503).", error.user_message
  end
end

class GraphProfileTest < Minitest::Test
  def test_reads_the_signed_in_users_profile_with_the_obo_token
    seen = nil
    transport = lambda do |method, url, token, payload|
      seen = { method: method, url: url, token: token, payload: payload }
      [200, {}, '{"id":"oid-1","displayName":"Jordan Student","userPrincipalName":"jstudent@contoso.edu"}']
    end
    me = GraphProfile.new(transport: transport).fetch("graph-token")

    assert_equal "oid-1", me["id"]
    assert_equal :get, seen[:method]
    assert_equal "https://graph.microsoft.com/v1.0/me?$select=id,displayName,userPrincipalName,mail", seen[:url]
    assert_equal "graph-token", seen[:token]
    assert_nil seen[:payload]
  end

  def test_graph_refusal_raises_with_graphs_code
    body = '{"error":{"code":"InvalidAuthenticationToken","message":"Access token validation failure."}}'
    error = assert_raises(GraphHttp::Error) { GraphProfile.new(transport: ->(*) { [401, {}, body] }).fetch("t") }
    assert_equal "InvalidAuthenticationToken", error.code
  end
end

class OverdueNoticesJobTest < Minitest::Test
  BODY = '{"overdue":[{"email":"jstudent@example.edu","title":"Calculus","due_date":"2026-11-01"}]}'

  def test_entra_mode_uses_client_credentials
    token_client = Object.new
    def token_client.acquire(scope:) = EntraAuth::Token.new(access_token: "app-token-for-#{scope}")
    sent = nil
    out = StringIO.new
    job = OverdueNoticesJob.new(api_url: "http://patron-api", mode: "entra", token_client: token_client,
                                scope: "api://patron/.default",
                                transport: ->(url, headers) { sent = [url, headers]; [200, BODY] }, out: out)

    assert_equal 1, job.run
    assert_equal "http://patron-api/api/v1/notices/overdue", sent[0]
    assert_equal "Bearer app-token-for-api://patron/.default", sent[1]["Authorization"]
    assert_includes out.string, "client credentials"
  end

  def test_legacy_mode_uses_the_api_key
    sent = nil
    job = OverdueNoticesJob.new(api_url: "http://patron-api", mode: "legacy", api_key: "k",
                                transport: ->(_u, h) { sent = h; [200, BODY] }, out: StringIO.new)
    job.run
    assert_equal({ "X-Api-Key" => "k" }, sent)
  end
end

class AutoProvisionTest < Minitest::Test
  def test_unknown_netid_is_provisioned_only_when_enabled
    assert_raises(PatronStore::NotFound) { demo_store.find!("visitor") }

    store = PatronStore.load(File.join(ROOT, "data/patrons.yml"), today: Date.new(2026, 11, 4), auto_provision: true)
    store.link_oid("newuser", "oid-new")
    assert_equal "oid-new", store.profile("newuser")[:entra_oid]
    assert_equal 3, store.loans("newuser").size
    assert_nil store.profile("jstudent")[:entra_oid], "the template record is copied, not shared"
  end
end
