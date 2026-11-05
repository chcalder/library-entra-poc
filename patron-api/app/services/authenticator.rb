# frozen_string_literal: true

require "openssl"

# Turns an incoming request into a Principal.
#
# AUTH_MODE controls what the API accepts during migration:
#   legacy  API key only (the "before" state)
#   both    API key OR Entra bearer token (dual-accept window while clients move)
#   entra   Entra bearer tokens only (API key retired)
class Authenticator
  class Unauthenticated < StandardError; end

  MODES = %w[legacy both entra].freeze

  def initialize(mode:, store:, legacy_api_key: nil, validator: nil, netid_claim: "preferred_username")
    raise ArgumentError, "AUTH_MODE must be one of #{MODES.join(', ')}" unless MODES.include?(mode)

    @mode = mode
    @store = store
    @legacy_api_key = legacy_api_key
    @validator = validator
    @netid_claim = netid_claim
  end

  # `headers` is anything responding to [] with HTTP header names
  # (ActionDispatch::Http::Headers in Rails, a Hash in tests).
  def call(headers)
    authorization = headers["Authorization"].to_s
    api_key = headers["X-Api-Key"].to_s

    # ENTRA MIGRATION (phase 1, API-2): a Bearer token takes the Entra path; the API-key
    # branch below is the pre-migration code, kept working until phase 3.
    if authorization.start_with?("Bearer ")
      entra(authorization.delete_prefix("Bearer ").strip)
    elsif !api_key.empty?
      legacy(api_key, headers["X-Remote-User"].to_s.strip)
    else
      raise Unauthenticated, "No credentials supplied"
    end
  end

  private

  # ENTRA MIGRATION (phase 1, API-1 + AUTH-3): validate the token (signature, issuer,
  # audience, expiry), build the caller from its claims, and link a user's oid to their NetID.
  def entra(token)
    raise Unauthenticated, "Bearer tokens are not accepted in legacy mode" if @mode == "legacy"

    claims = @validator.validate(token)
    principal = Principal.from_claims(claims, assertion: token, netid_claim: @netid_claim)
    @store.link_oid(principal.netid, principal.oid) if principal.delegated? && principal.netid
    principal
  end

  def legacy(api_key, remote_user)
    # ENTRA MIGRATION (phase 3): AUTH_MODE=entra retires the API key.
    raise Unauthenticated, "API keys are no longer accepted; use an Entra access token" if @mode == "entra"
    unless @legacy_api_key && OpenSSL.secure_compare(api_key, @legacy_api_key)
      raise Unauthenticated, "Invalid API key"
    end

    if remote_user.empty?
      Principal.legacy(netid: nil, roles: ["LegacyService"])
    else
      netid = remote_user.downcase
      Principal.legacy(netid: netid, roles: @store.roles_for(netid))
    end
  end
end
