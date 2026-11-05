# frozen_string_literal: true

# ENTRA MIGRATION (phase 2, AUTH-1): new file.
# AFTER state only: OpenID Connect sign-in with Microsoft Entra ID via the
# omniauth-entra-id strategy. In CAS mode no OmniAuth middleware is mounted.
#
# Reads ENV directly (not AppConfig) because initializers run before the
# autoloader is ready for reloadable constants.
if ENV.fetch("AUTH_MODE", "cas") == "entra"
  require "omniauth/strategies/entra_id"

  module OmniAuth
    module Strategies
      # ENTRA MIGRATION (AUTH-7 + API-4):
      # Step-up: when the Patron API (or Graph, via OBO) returned a claims
      # challenge, ApplicationController#step_up stores the claims in the
      # session; this adds them to THIS request's /authorize parameters.
      # Built per request (never written to the shared strategy options),
      # so one user's claims can't leak into another user's sign-in.
      class EntraIdStepUp < EntraId
        option :name, "entra_id" # keeps the /auth/entra_id paths

        def authorize_params
          super.tap do |params|
            claims = session[:pending_claims] || session["pending_claims"]
            params[:claims] = claims if claims.present?
          end
        end

        # ENTRA MIGRATION (phase 2, demo): the ID token on its own. The gem's raw_info
        # merges ID token and access token claims (access token wins), so it is not the
        # ID token. The gem has already checked iss, aud, exp and nbf on this payload; the
        # signature is not re-checked because the token came straight from the token
        # endpoint over TLS (OIDC Core 3.1.3.7).
        def extra
          header, payload = access_token.params["id_token"].to_s.split(".").first(2).map do |part|
            JSON.parse(Base64.urlsafe_decode64(part + "=" * (-part.length % 4)))
          end
          super.merge(id_token: { header: header, claims: payload })
        rescue ArgumentError, JSON::ParserError
          super
        end
      end
    end
  end

  OmniAuth.config.allowed_request_methods = [:post] # request phase is POST + CSRF token
  OmniAuth.config.full_host = ENV["PORTAL_BASE_URL"] if ENV["PORTAL_BASE_URL"].present?
  OmniAuth.config.logger = Rails.logger

  Rails.application.config.middleware.use OmniAuth::Builder do
    provider OmniAuth::Strategies::EntraIdStepUp,
             client_id: ENV.fetch("ENTRA_CLIENT_ID"),
             client_secret: ENV.fetch("ENTRA_CLIENT_SECRET"),
             tenant_id: ENV.fetch("ENTRA_TENANT_ID"),
             # One sign-in returns an ID token (who the user is) and an access
             # token for the Patron API (what the portal may call on their behalf).
             # offline_access adds a refresh token.
             scope: "openid profile email offline_access #{ENV.fetch('PATRON_API_SCOPES', '')}".strip
  end
end
