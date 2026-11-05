# frozen_string_literal: true

module EntraAuth
  class Error < StandardError; end

  # The token endpoint refused the request (bad secret, missing consent, ...).
  class TokenError < Error
    attr_reader :error, :description, :status

    def initialize(error, description = nil, status: nil)
      @error = error
      @description = description
      @status = status
      super([error, description].compact.join(": "))
    end

    # AADSTS65001: the user or admin has not consented to the permission.
    def consent_required?
      description.to_s.include?("AADSTS65001")
    end
  end

  # Entra needs the user to satisfy extra claims (MFA, an authentication
  # context, a CAE event). Only the client that owns the browser can do this,
  # so a middle tier must pass the claims back up to its caller.
  class ClaimsChallengeRequired < Error
    attr_reader :claims, :error, :description

    def initialize(claims, error: "interaction_required", description: nil)
      @claims = claims
      @error = error
      @description = description
      super("Claims challenge required (#{error})")
    end
  end

  # An incoming access token failed validation.
  class InvalidToken < Error; end
end
