# frozen_string_literal: true

# All portal settings come from the environment (12-factor), so the same image
# runs as the CAS "before" state or the Entra "after" state.
module AppConfig
  module_function

  # "cas" (before) or "entra" (after)
  def auth_mode = ENV.fetch("AUTH_MODE", "cas")
  def entra? = auth_mode == "entra"
  def cas? = !entra?

  def patron_api_url = ENV.fetch("PATRON_API_URL", "http://localhost:3001")
  def patron_api_key = ENV["PATRON_API_KEY"]

  # ENTRA MIGRATION (phase 2): everything from here to entra_logout_url is new.
  # Delegated scopes the portal requests for the Patron API, e.g.
  # "api://<patron-api-client-id>/Patron.Read api://<patron-api-client-id>/Patron.Manage"
  def patron_api_scopes = ENV.fetch("PATRON_API_SCOPES", "")

  def refresh_scope = "#{patron_api_scopes} offline_access".strip

  def entra_config = EntraAuth::Config.from_env("ENTRA_")

  def entra_logout_url(post_logout_redirect)
    authority = ENV.fetch("ENTRA_AUTHORITY", EntraAuth::DEFAULT_AUTHORITY).chomp("/")
    query = URI.encode_www_form(post_logout_redirect_uri: post_logout_redirect)
    "#{authority}/#{ENV.fetch('ENTRA_TENANT_ID')}/oauth2/v2.0/logout?#{query}"
  end

  def cas_client
    CasClient.new(
      login_url: ENV.fetch("CAS_LOGIN_URL", "http://localhost:8081/cas/login"),
      validate_url: ENV.fetch("CAS_VALIDATE_URL", "http://localhost:8081/cas/p3/serviceValidate"),
      logout_url: ENV.fetch("CAS_LOGOUT_URL", "http://localhost:8081/cas/logout")
    )
  end

  # Shown in the page footer so demo viewers can see which phase is running.
  def phase_label = ENV.fetch("MIGRATION_PHASE_LABEL", entra? ? "Microsoft Entra ID" : "CAS")
end
