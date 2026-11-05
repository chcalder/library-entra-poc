# frozen_string_literal: true

module EntraAuth
  # Secretless client credential for apps hosted in Azure Container Apps or
  # App Service: the app's user-assigned managed identity gets a token for
  # api://AzureADTokenExchange, and the app registration trusts that identity
  # through a federated identity credential (FIC).
  #
  # Setup (once per app registration):
  #   az ad app federated-credential create --id <app-id> --parameters '{
  #     "name": "container-apps-mi",
  #     "issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0",
  #     "subject": "<managed identity principal (object) id>",
  #     "audiences": ["api://AzureADTokenExchange"] }'
  class ManagedIdentityAssertion
    AUDIENCE = "api://AzureADTokenExchange"

    def initialize(managed_identity_client_id:, env: ENV, http: Http, clock: -> { Time.now })
      @mi_client_id = managed_identity_client_id
      @env = env
      @http = http
      @clock = clock
      @mutex = Mutex.new
    end

    def call
      @mutex.synchronize do
        return @assertion if @assertion && @expires_at - 300 > @clock.call

        endpoint = @env.fetch("IDENTITY_ENDPOINT") do
          raise Error, "IDENTITY_ENDPOINT not set: managed identity is only available when hosted in Azure"
        end
        uri = URI(endpoint)
        query = { "api-version" => "2019-08-01", "resource" => AUDIENCE }
        query["client_id"] = @mi_client_id if @mi_client_id
        uri.query = URI.encode_www_form(query)
        status, body = @http.get_json(uri, headers: { "X-IDENTITY-HEADER" => @env.fetch("IDENTITY_HEADER") })
        raise TokenError.new("managed_identity_failed", body.to_s, status: status) unless status == 200

        @assertion = body.fetch("access_token")
        @expires_at = Time.at(body.fetch("expires_on").to_i)
        @assertion
      end
    end
  end
end
