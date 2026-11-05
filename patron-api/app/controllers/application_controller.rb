# frozen_string_literal: true

class ApplicationController < ActionController::API
  before_action :authenticate!

  attr_reader :principal

  # ENTRA MIGRATION (phases 1-2): every handler here except PatronStore::NotFound is new.
  # Declared first so the more specific handlers below take precedence.
  rescue_from EntraAuth::Error do |e|
    Rails.logger.error("Entra error: #{e.class}: #{e.message}")
    render json: { error: "identity_service_unavailable", message: "Could not reach Microsoft Entra ID" },
           status: :service_unavailable
  end

  rescue_from Authenticator::Unauthenticated, EntraAuth::InvalidToken do |e|
    response.headers["WWW-Authenticate"] = %(Bearer error="invalid_token", error_description="#{e.message.tr('"', "'")}")
    render json: { error: "unauthorized", message: e.message }, status: :unauthorized
  end

  rescue_from PatronStore::NotFound do |e|
    render json: { error: "not_found", message: e.message }, status: :not_found
  end

  # ENTRA MIGRATION (phase 2, API-4): a downstream call (OBO or Graph) needs the user to
  # satisfy more claims. Pass the challenge up so the portal can send the user back to Entra.
  rescue_from EntraAuth::ClaimsChallengeRequired do |e|
    challenge(e.claims, e.description || "Additional verification required")
  end

  rescue_from EntraAuth::TokenError do |e|
    Rails.logger.error("Token endpoint error: #{e.message}")
    message = e.consent_required? ? "Admin consent for the downstream API is missing" : "Downstream token request failed"
    render json: { error: "downstream_auth_failed", message: message }, status: :bad_gateway
  end

  # ENTRA MIGRATION (phase 2, API-3): the OBO exchange worked but Graph refused the call
  # (e.g. no mailbox). Say why, instead of failing with a 500.
  rescue_from GraphHttp::Error do |e|
    Rails.logger.error("Graph error: #{e.message}")
    render json: { error: "graph_error", graph_error: e.code, message: e.user_message }, status: :bad_gateway
  end

  private

  # ENTRA MIGRATION (phase 1, API-2): one line per authenticated request, so the dual-accept
  # window can be watched: the API key can be retired once no `legacy` lines remain.
  def authenticate!
    @principal = AppServices.authenticator.call(request.headers)
    Rails.logger.info({ authenticated_via: principal.kind, actor: principal.audit,
                        request: "#{request.method} #{request.path}" }.to_json)
  end

  def store = AppServices.store

  def forbid(message)
    render json: { error: "forbidden", message: message }, status: :forbidden
  end

  # ENTRA MIGRATION (API-4): 401 with a claims challenge the portal turns into a step-up.
  def challenge(claims, message)
    response.headers["WWW-Authenticate"] = EntraAuth::ClaimsChallenge.header(claims)
    render json: { error: "insufficient_claims", message: message }, status: :unauthorized
  end

  # --- Authorization helpers ---------------------------------------------
  # Each returns true when it has already rendered a refusal; use as
  #   return if require_user!

  def require_user!
    forbid("This endpoint acts for a signed-in user") unless principal.user?
  end

  # ENTRA MIGRATION (phase 1, API-1): delegated tokens must carry the scope. Legacy API-key callers are fully
  # trusted, which is exactly the weakness the migration removes.
  def require_scope!(scope)
    forbid("Token is missing the #{scope} scope") if principal.delegated? && !principal.scope?(scope)
  end

  # ENTRA MIGRATION (phase 2, API-3): Graph calls need the patron's own token to exchange.
  def require_delegated!
    return if principal.delegated?

    render json: {
      error: "requires_delegated_identity",
      message: "Microsoft Graph calls need the patron's own Entra token. With an API key the Patron API " \
               "only has a NetID in a header, which Microsoft Graph cannot accept."
    }, status: :not_implemented
  end

  # ENTRA MIGRATION (phase 2, API-3 + API-6): exchange the caller's token (audience = this API)
  # for a Graph token (audience = Graph), still as the caller. Cached per user and scope.
  def obo_graph_token
    AppServices.obo.acquire(user_assertion: principal.assertion, scope: AppServices.graph_scope,
                            user_key: principal.oid)
  end

  def require_role!(role)
    forbid("Requires the #{role} role") unless principal.role?(role)
  end

  # ENTRA MIGRATION (phase 1, API-5): app-only tokens need the application permission.
  def require_app_role!(role)
    return if principal.legacy_service?
    return if principal.app? && principal.role?(role)

    forbid("Requires an app-only token with the #{role} application permission")
  end

  # ENTRA MIGRATION (optional, AUTH-7): step-up for sensitive data via a Conditional Access
  # authentication context.
  def require_auth_context!(context_id)
    return if context_id.empty? || !principal.delegated? || principal.acrs.include?(context_id)

    challenge(EntraAuth::ClaimsChallenge.auth_context(context_id), "Multi-factor verification required for fines")
  end

  def audit(action, **details)
    Rails.logger.info({ audit: action, actor: principal.audit, **details }.to_json)
  end
end
