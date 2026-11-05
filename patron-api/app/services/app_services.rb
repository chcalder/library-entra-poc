# frozen_string_literal: true

# Wiring for the API's collaborators, built once from environment variables.
module AppServices
  module_function

  def auth_mode
    ENV.fetch("AUTH_MODE", "legacy")
  end

  def entra_enabled?
    auth_mode != "legacy"
  end

  def store
    PatronStore.instance
  end

  # ENTRA MIGRATION (phase 1, API-1): the API's own app registration (ENTRA_TENANT_ID,
  # ENTRA_CLIENT_ID, ENTRA_CLIENT_SECRET). The token validator below is only built when
  # AUTH_MODE is "both" or "entra".
  def entra_config
    @entra_config ||= EntraAuth::Config.from_env("ENTRA_")
  end

  def authenticator
    @authenticator ||= Authenticator.new(
      mode: auth_mode,
      store: store,
      legacy_api_key: ENV["LEGACY_API_KEY"],
      validator: entra_enabled? ? EntraAuth::TokenValidator.new(entra_config) : nil,
      netid_claim: ENV.fetch("NETID_CLAIM", "preferred_username")
    )
  end

  # ENTRA MIGRATION (phase 2, API-3 + API-6): OBO tokens for Graph, cached per user (oid) + scope.
  def obo
    @obo ||= EntraAuth::OboClient.new(entra_config)
  end

  def graph_scope
    ENV.fetch("GRAPH_SCOPE", "https://graph.microsoft.com/.default")
  end

  def graph_calendar
    @graph_calendar ||= GraphCalendar.new(time_zone: ENV.fetch("GRAPH_TIME_ZONE", "UTC"))
  end

  def graph_profile
    @graph_profile ||= GraphProfile.new
  end

  # ENTRA MIGRATION (optional, AUTH-7, needs Entra ID P1):
  # Conditional Access authentication context ID (e.g. "c1") required to view
  # fines. Empty or "none" = no step-up.
  def fines_auth_context
    value = ENV["FINES_AUTH_CONTEXT"].to_s.strip
    value.casecmp?("none") ? "" : value
  end
end
