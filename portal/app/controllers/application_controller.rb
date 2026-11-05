# frozen_string_literal: true

class ApplicationController < ActionController::Base
  before_action :require_login
  helper_method :current_identity, :signed_in?, :api_roles, :librarian?

  # rescue_from handlers declared later win, so the generic one comes first.
  # ENTRA MIGRATION (phase 2): EntraTokenStore::SessionExpired and ClaimsChallenge are new.
  rescue_from PatronApiClient::Error, with: :api_error
  rescue_from PatronApiClient::Forbidden, with: :forbidden
  rescue_from PatronApiClient::Unauthorized, EntraTokenStore::SessionExpired, with: :session_expired
  rescue_from PatronApiClient::ClaimsChallenge, with: :step_up

  private

  def current_identity
    @current_identity ||= Identity.from_session(session[:identity])
  end

  def signed_in? = current_identity.present?

  def require_login
    return if signed_in?

    redirect_to login_path(return_to: request.get? ? request.fullpath : nil)
  end

  # --- The one place the migration changes how the portal calls the API ---
  # ENTRA MIGRATION (phase 2): bearer token in Entra mode, API key + NetID header before.
  def patron_api
    @patron_api ||= PatronApiClient.new(base_url: AppConfig.patron_api_url, credentials: api_credentials)
  end

  def api_credentials
    if AppConfig.entra?
      PatronApiClient::BearerCredentials.new(-> { token_store.access_token })
    else
      PatronApiClient::LegacyCredentials.new(AppConfig.patron_api_key, current_identity&.netid)
    end
  end

  # ENTRA MIGRATION (phase 2, AUTH-5): server-side tokens, refreshed before they expire.
  def token_store
    EntraTokenStore.new(session, refresh_client: EntraAuth::RefreshClient.new(AppConfig.entra_config),
                                 scope: AppConfig.refresh_scope)
  end

  # ENTRA MIGRATION (AUTH-4 + API-8): roles come from the API (/me), never from decoding the access token.
  def api_roles
    session[:roles] ||= patron_api.me["roles"]
  rescue PatronApiClient::Error, EntraTokenStore::SessionExpired
    []
  end

  def librarian? = api_roles.include?("Librarian")

  # --- Error handling -----------------------------------------------------

  # ENTRA MIGRATION (phase 2, API-4 + AUTH-7):
  # The API (or Graph, via OBO) needs more claims: MFA, an auth context, a
  # CAE event. Send the user back to Entra with those claims.
  def step_up(error)
    session[:pending_claims] = error.claims
    session[:return_to] = request.get? ? request.fullpath : safe_referer_path
    @message = error.message
    render "sessions/step_up", status: :unauthorized
  end

  def session_expired(error)
    Rails.logger.info("Session expired: #{error.message}")
    reset_session
    redirect_to login_path, alert: "Your session has expired. Please sign in again."
  end

  def forbidden(error)
    @message = error.message
    render "shared/error", status: :forbidden
  end

  def api_error(error)
    @message = error.message
    render "shared/error", status: :bad_gateway
  end

  def safe_referer_path
    path = URI(request.referer.to_s).path
    path.start_with?("/") && !path.start_with?("//") ? path : root_path
  rescue URI::InvalidURIError
    root_path
  end
end
