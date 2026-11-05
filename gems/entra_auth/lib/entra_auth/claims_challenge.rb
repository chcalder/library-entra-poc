# frozen_string_literal: true

module EntraAuth
  # Moving a claims challenge from an API back to the client.
  #
  # API side:    401 + WWW-Authenticate: Bearer ..., error="insufficient_claims", claims="<base64 json>"
  # Client side: parse the header, send the user to /authorize with claims=<json>
  module ClaimsChallenge
    module_function

    def header(claims_json, authority: DEFAULT_AUTHORITY, error: "insufficient_claims")
      encoded = [claims_json].pack("m0")
      %(Bearer realm="", authorization_uri="#{authority}/common/oauth2/authorize", ) +
        %(error="#{error}", claims="#{encoded}")
    end

    # Returns the claims JSON string, or nil when the header has no challenge.
    def parse(header)
      match = header.to_s.match(/claims="([^"]+)"/)
      return nil unless match

      value = match[1]
      decoded = value.unpack1("m").force_encoding(Encoding::UTF_8)
      JSON.parse(decoded)
      decoded
    rescue ArgumentError, JSON::ParserError
      begin
        JSON.parse(value)
        value
      rescue JSON::ParserError
        nil
      end
    end

    # Claims requesting a Conditional Access authentication context (e.g. "c1"
    # mapped to "require MFA" for fines and payments).
    def auth_context(id)
      JSON.generate(access_token: { acrs: { essential: true, value: id } })
    end
  end
end
