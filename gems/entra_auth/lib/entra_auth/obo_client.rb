# frozen_string_literal: true

module EntraAuth
  # On-Behalf-Of: a middle-tier API exchanges the access token it received
  # (whose audience is itself) for a token to a downstream API, still as the
  # signed-in user.
  #
  # Rules that matter:
  #   * user_assertion must be the raw incoming ACCESS token for this API,
  #     never an ID token and never a token for another audience.
  #   * One resource per request: Graph and the Patron API need separate calls.
  #   * Cache per user (oid) + scope.
  class OboClient
    GRANT_TYPE = "urn:ietf:params:oauth:grant-type:jwt-bearer"

    def initialize(config, cache: TokenCache.new, endpoint: TokenEndpoint.new(config))
      @cache = cache
      @endpoint = endpoint
    end

    def acquire(user_assertion:, scope:, user_key:)
      raise ArgumentError, "user_key (the caller's oid) is required" if user_key.to_s.empty?

      @cache.fetch("obo:#{user_key}:#{scope}") do
        @endpoint.request(
          grant_type: GRANT_TYPE,
          assertion: user_assertion,
          scope: scope,
          requested_token_use: "on_behalf_of"
        )
      end
    end
  end
end
