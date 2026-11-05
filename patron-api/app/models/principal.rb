# frozen_string_literal: true

# Who is calling the Patron API, however they authenticated.
#
#   :legacy     API key (+ optional X-Remote-User). The API trusts the caller's
#               word about which user it is acting for. This is what OBO replaces.
#   :delegated  Entra access token with `scp`: a user signed in to a client app.
#   :app        Entra access token with no `scp` (app-only, client credentials).
Principal = Struct.new(:kind, :netid, :oid, :name, :roles, :scopes, :acrs, :app_id, :assertion,
                       keyword_init: true) do
  # ENTRA MIGRATION (phase 1, API-1): the caller from a validated Entra token.
  # Pre-migration callers come from Principal.legacy below.
  def self.from_claims(claims, assertion:, netid_claim: "preferred_username")
    scopes = claims["scp"].to_s.split
    app_only = scopes.empty? || claims["idtyp"] == "app"
    new(
      kind: app_only ? :app : :delegated,
      netid: app_only ? nil : netid_from(claims[netid_claim]),
      oid: claims["oid"],
      name: claims["name"],
      roles: Array(claims["roles"]),
      scopes: scopes,
      acrs: Array(claims["acrs"]),
      app_id: claims["azp"] || claims["appid"],
      assertion: assertion
    )
  end

  def self.legacy(netid:, roles:)
    new(kind: :legacy, netid: netid, roles: roles, scopes: [], acrs: [], app_id: "legacy-api-key")
  end

  # "jstudent@contoso.edu" -> "jstudent". Swap NETID_CLAIM for a custom claim
  # (e.g. a directory extension holding the NetID) when UPNs don't match NetIDs.
  def self.netid_from(value)
    value.to_s.split("@").first.to_s.downcase.then { |v| v.empty? ? nil : v }
  end

  def delegated? = kind == :delegated
  def app? = kind == :app
  def legacy? = kind == :legacy
  def user? = (delegated? || legacy?) && !netid.nil?
  def legacy_service? = legacy? && netid.nil?
  def role?(role) = roles.include?(role)
  def scope?(scope) = scopes.include?(scope)

  def audit
    { kind: kind, netid: netid, oid: oid, app_id: app_id }.compact
  end
end
