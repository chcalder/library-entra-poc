# frozen_string_literal: true

module EntraAuth
  # Validates an incoming Entra v2.0 access token for THIS API:
  #   signature (RS256, Entra JWKS), expiry/nbf, issuer = this tenant,
  #   audience = this API's client ID (or its api:// URI), tid = this tenant.
  #
  # Authorization (scp for delegated calls, roles for app-only calls) is the
  # API's job after validation; see the Patron API's Authenticator.
  class TokenValidator
    def initialize(config, audiences: nil, jwks: JwksProvider.new(config), leeway: 60)
      @config = config
      @audiences = audiences || [config.client_id, "api://#{config.client_id}"]
      @jwks = jwks
      @leeway = leeway
    end

    def validate(token)
      require "jwt"

      loader = lambda do |options|
        force = options[:kid_not_found] || options[:invalidate]
        JWT::JWK::Set.new(@jwks.keys(force: force))
      end

      payload, _header = JWT.decode(
        token, nil, true,
        algorithms: ["RS256"],
        jwks: loader,
        aud: @audiences, verify_aud: true,
        iss: @config.issuer, verify_iss: true,
        verify_iat: true,
        leeway: @leeway
      )

      raise InvalidToken, "token issued for another tenant" unless payload["tid"] == @config.tenant_id

      payload
    rescue JWT::DecodeError => e
      raise InvalidToken, e.message
    end
  end
end
