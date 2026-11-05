# frozen_string_literal: true

module EntraAuth
  # Identity of one confidential client (app registration) in one tenant.
  #
  # Credentials, in order of preference for production:
  #   1. client_assertion: a callable returning a signed assertion, e.g. a
  #      managed identity token used as a federated identity credential (no
  #      secret to store or rotate). See ManagedIdentityAssertion.
  #   2. client_secret: simplest for a POC; keep it in Key Vault.
  Config = Struct.new(:tenant_id, :client_id, :client_secret, :client_assertion, :authority,
                      keyword_init: true) do
    # Reads <PREFIX>CLIENT_ID / <PREFIX>CLIENT_SECRET plus ENTRA_TENANT_ID.
    # Set <PREFIX>USE_MANAGED_IDENTITY_FIC=true to use a managed identity
    # federated credential instead of a secret.
    def self.from_env(prefix = "ENTRA_", env: ENV)
      assertion =
        if env["#{prefix}USE_MANAGED_IDENTITY_FIC"] == "true"
          ManagedIdentityAssertion.new(managed_identity_client_id: env["AZURE_CLIENT_ID"], env: env)
        end
      new(
        tenant_id: env.fetch("ENTRA_TENANT_ID"),
        client_id: env.fetch("#{prefix}CLIENT_ID"),
        client_secret: assertion ? nil : env["#{prefix}CLIENT_SECRET"],
        client_assertion: assertion,
        authority: env.fetch("ENTRA_AUTHORITY", DEFAULT_AUTHORITY)
      )
    end

    def authority_base
      (authority || DEFAULT_AUTHORITY).chomp("/")
    end

    def token_url
      "#{authority_base}/#{tenant_id}/oauth2/v2.0/token"
    end

    def jwks_url
      "#{authority_base}/#{tenant_id}/discovery/v2.0/keys"
    end

    # Issuer of v2.0 access tokens. The API app registration must set
    # accessTokenAcceptedVersion = 2 or tokens arrive with the v1 issuer.
    def issuer
      "#{authority_base}/#{tenant_id}/v2.0"
    end

    def client_credentials_form
      if client_assertion
        {
          client_id: client_id,
          client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
          client_assertion: client_assertion.call
        }
      elsif client_secret && !client_secret.empty?
        { client_id: client_id, client_secret: client_secret }
      else
        raise Error, "No credential configured for client #{client_id}"
      end
    end
  end
end
