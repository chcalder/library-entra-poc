# frozen_string_literal: true

# ENTRA MIGRATION: this whole gem is new; it has no CAS or API-key equivalent.
# EntraAuth: the small, reusable token toolkit shared by the Library Portal,
# the Patron Record API and the overdue-notices job.
#
# Everything except TokenValidator uses only the Ruby standard library, so the
# token flows (OBO, client credentials, refresh) are visible and testable
# without extra dependencies. TokenValidator uses the `jwt` gem, loaded lazily.
#
# Package this once (internal gem server or git source) and reuse it across
# campus Rails apps instead of re-implementing token handling per app.

require "json"
require "net/http"
require "uri"

module EntraAuth
  DEFAULT_AUTHORITY = "https://login.microsoftonline.com"
end

require_relative "entra_auth/version"
require_relative "entra_auth/errors"
require_relative "entra_auth/http"
require_relative "entra_auth/config"
require_relative "entra_auth/managed_identity_assertion"
require_relative "entra_auth/token"
require_relative "entra_auth/token_cache"
require_relative "entra_auth/token_endpoint"
require_relative "entra_auth/obo_client"
require_relative "entra_auth/client_credentials_client"
require_relative "entra_auth/refresh_client"
require_relative "entra_auth/claims_challenge"
require_relative "entra_auth/jwks_provider"
require_relative "entra_auth/token_validator"
