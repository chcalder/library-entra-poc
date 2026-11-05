# frozen_string_literal: true

module EntraAuth
  Token = Struct.new(:access_token, :refresh_token, :expires_at, :scope, keyword_init: true) do
    def self.from_response(body, clock: -> { Time.now })
      new(
        access_token: body.fetch("access_token"),
        refresh_token: body["refresh_token"],
        expires_at: clock.call + body.fetch("expires_in", 3599).to_i,
        scope: body["scope"]
      )
    end

    def expired?(skew: 60, now: Time.now)
      expires_at - skew <= now
    end
  end
end
