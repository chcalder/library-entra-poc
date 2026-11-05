# frozen_string_literal: true

module EntraAuth
  # One place that talks to /oauth2/v2.0/token and turns its errors into
  # exceptions the application can act on.
  class TokenEndpoint
    def initialize(config, http: Http, clock: -> { Time.now })
      @config = config
      @http = http
      @clock = clock
    end

    def request(form)
      status, body = @http.post_form(URI(@config.token_url), form.merge(@config.client_credentials_form))
      return Token.from_response(body, clock: @clock) if status == 200 && body["access_token"]

      # Conditional Access (MFA, authentication context, CAE) shows up as
      # interaction_required / invalid_grant with a `claims` value.
      claims = body["claims"]
      if claims && !claims.to_s.empty?
        raise ClaimsChallengeRequired.new(claims, error: body["error"], description: body["error_description"])
      end

      raise TokenError.new(body["error"] || "http_#{status}", body["error_description"], status: status)
    end
  end
end
