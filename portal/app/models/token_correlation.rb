# frozen_string_literal: true

# ENTRA MIGRATION (phase 2, demo): lines up the tokens in a sign-in + On-Behalf-Of chain,
# so the Graph check page can show what stays the same (the user) and what changes at each
# hop (audience, the app holding the token, permissions).
#
#   ID token      portal's sign-in       aud = portal
#   access token  portal -> Patron API   aud = Patron API, held by the portal
#   OBO token     Patron API -> Graph    aud = Graph, held by the Patron API, still the user
#   Graph /me     Graph's answer         the user Graph acted for
class TokenCorrelation
  SOURCES = ["ID token (portal)", "Access token (Patron API)", "OBO token (Graph)", "Graph /me"].freeze

  # kind  :same    must be identical wherever present: this is the user being acted for
  #       :changes expected to differ from hop to hop
  #       :info    shown for reference
  Row = Struct.new(:claim, :values, :kind, :note, keyword_init: true) do
    def consistent? = values.compact.uniq.size == 1 && values.compact.size > 1
  end

  FIELDS = [
    { claim: "oid", kind: :same, read: ->(c) { c["oid"] }, graph: "id",
      note: "The user's object ID: the identity acted on behalf of. Identical in every token and in Graph's answer." },
    { claim: "tid", kind: :same, read: ->(c) { c["tid"] },
      note: "Tenant. The whole chain stays inside one directory." },
    { claim: "preferred_username / upn", kind: :same, read: ->(c) { c["preferred_username"] || c["upn"] },
      graph: "user_principal_name", note: "Sign-in name. Friendly, but can change; correlate on oid." },
    { claim: "aud", kind: :changes, read: ->(c) { c["aud"] },
      note: "Who each token is for: the portal, then the Patron API, then Microsoft Graph." },
    { claim: "azp / appid", kind: :changes, read: ->(c) { c["azp"] || c["appid"] },
      note: "The app holding the token. In the OBO token it is the Patron API: the API acts, as the user." },
    { claim: "scp", kind: :changes, read: ->(c) { c["scp"] },
      note: "Delegated permissions. ID tokens carry none; each access token has only its audience's scopes." },
    { claim: "sub", kind: :info, read: ->(c) { c["sub"] },
      note: "Pairwise: Entra issues a different sub for the same user per app, so never correlate on it." },
    { claim: "iss", kind: :info, read: ->(c) { c["iss"] },
      note: "Issuer. Graph may issue v1 tokens (sts.windows.net) even when your apps use v2." }
  ].freeze

  def initialize(id_token:, access_token:, obo_token:, graph_user:)
    @tokens = [id_token, access_token, obo_token].map { |t| t.is_a?(Hash) ? t : nil }
    @graph_user = graph_user || {}
  end

  def rows
    FIELDS.map do |field|
      values = @tokens.map { |claims| claims && field[:read].call(claims) }
      values << (field[:graph] && @graph_user[field[:graph]])
      Row.new(claim: field[:claim], values: values, kind: field[:kind], note: field[:note])
    end
  end

  def missing_sources = SOURCES.first(3).select.with_index { |_, i| @tokens[i].nil? }
end
