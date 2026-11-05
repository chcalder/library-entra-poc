# frozen_string_literal: true

module EntraAuth
  # Used by the portal to renew its access token for the Patron API without
  # sending the user back through sign-in.
  class RefreshClient
    def initialize(config, endpoint: TokenEndpoint.new(config))
      @endpoint = endpoint
    end

    def refresh(refresh_token:, scope:)
      @endpoint.request(grant_type: "refresh_token", refresh_token: refresh_token, scope: scope)
    end
  end
end
