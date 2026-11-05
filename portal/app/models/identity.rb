# frozen_string_literal: true

# The signed-in user, normalized so the rest of the portal doesn't care
# whether CAS or Entra authenticated them. This is the attribute-mapping seam
# of the migration (see docs/01-auth-upgrade-playbook.md, "Attribute mapping").
#
#   CAS attribute           Entra (OIDC) claim
#   ---------------------   --------------------------------------------
#   cas:user (NetID)        preferred_username local part (or a custom claim)
#   displayName             name
#   mail                    email (optional claim) / preferred_username
#   eduPersonAffiliation    app roles on the Patron API (read via /me, not here)
#   (none)                  oid: immutable object ID, the long-term key
Identity = Struct.new(:netid, :name, :email, :affiliations, :oid, :source, keyword_init: true) do
  def self.from_cas(result)
    attrs = result.attributes
    new(
      netid: result.user.downcase,
      name: attrs["displayName"]&.first || result.user,
      email: attrs["mail"]&.first,
      affiliations: attrs.fetch("eduPersonAffiliation", []),
      source: "cas"
    )
  end

  # ENTRA MIGRATION (phase 2, AUTH-2): the Entra side of the seam, mirroring from_cas.
  # auth: OmniAuth auth hash from the entra_id strategy.
  def self.from_entra(auth)
    data = auth.respond_to?(:to_hash) ? auth.to_hash : auth
    raw = data.dig("extra", "raw_info") || {}
    info = data["info"] || {}
    username = raw["preferred_username"] || info["email"].to_s
    new(
      netid: username.split("@").first.to_s.downcase,
      name: raw["name"] || info["name"] || username,
      email: raw["email"] || info["email"] || username,
      affiliations: [],
      oid: raw["oid"],
      source: "entra"
    )
  end

  def self.from_session(hash)
    return nil unless hash

    new(**hash.transform_keys(&:to_sym))
  end

  def to_session = to_h.transform_keys(&:to_s)
end
