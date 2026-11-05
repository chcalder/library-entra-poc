# frozen_string_literal: true

# ENTRA MIGRATION (phase 2, AUTH-5): new file.
# Holds the portal's access token for the Patron API in the server-side
# session and refreshes it before it expires.
#
# Tokens never go in a cookie: the session store is server-side (cache_store),
# and access + refresh tokens together exceed the 4 KB cookie limit anyway.
class EntraTokenStore
  class SessionExpired < StandardError; end

  KEY = "entra_tokens"

  def initialize(session, refresh_client:, scope:, clock: -> { Time.now })
    @session = session
    @refresh_client = refresh_client
    @scope = scope
    @clock = clock
  end

  # credentials: OmniAuth credentials (token, refresh_token, expires_at) or an EntraAuth::Token.
  def store(credentials)
    data = credentials.to_h.transform_keys(&:to_s)
    @session[KEY] = {
      "access_token" => data["token"] || data["access_token"],
      "refresh_token" => data["refresh_token"] || @session.dig(KEY, "refresh_token"),
      "expires_at" => (data["expires_at"] || @clock.call.to_i + 3000).to_i
    }
  end

  def access_token
    tokens = @session[KEY] or raise SessionExpired, "Not signed in with Entra"
    return tokens["access_token"] if tokens["expires_at"] - 60 > @clock.call.to_i

    refresh(tokens)
  end

  private

  def refresh(tokens)
    raise SessionExpired, "Access token expired and no refresh token is available" unless tokens["refresh_token"]

    token = @refresh_client.refresh(refresh_token: tokens["refresh_token"], scope: @scope)
    store(access_token: token.access_token, refresh_token: token.refresh_token, expires_at: token.expires_at.to_i)
    token.access_token
  rescue EntraAuth::ClaimsChallengeRequired => e
    # Conditional Access wants more (e.g. MFA): use the normal step-up page.
    raise PatronApiClient::ClaimsChallenge.new(e.claims, "Additional verification required")
  rescue EntraAuth::Error => e
    raise SessionExpired, "Token refresh failed: #{e.message}"
  end
end
