# frozen_string_literal: true

module EntraAuth
  # Client credentials: the app calls an API as itself, with no user present
  # (batch jobs, sync processes). Permissions come from app roles granted by
  # an admin, and the scope is always "<resource>/.default".
  class ClientCredentialsClient
    def initialize(config, cache: TokenCache.new, endpoint: TokenEndpoint.new(config))
      @cache = cache
      @endpoint = endpoint
    end

    def acquire(scope:)
      unless scope.end_with?("/.default")
        raise ArgumentError, "client credentials scope must be '<resource>/.default', got #{scope.inspect}"
      end

      @cache.fetch("cc:#{scope}") do
        @endpoint.request(grant_type: "client_credentials", scope: scope)
      end
    end
  end
end
