# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# ENTRA MIGRATION (phase 2, API-3): new file.
# HTTP and error handling shared by the Microsoft Graph calls the Patron API
# makes with an OBO token (GraphCalendar, GraphProfile).
module GraphHttp
  BASE_URL = "https://graph.microsoft.com/v1.0"

  # Graph refused the call. `code` is Graph's own error code, so the API can
  # say why instead of failing with a 500.
  class Error < StandardError
    MESSAGES = {
      "MailboxNotEnabledForRESTAPI" => "Microsoft Graph accepted your identity, but your account has no " \
                                       "Exchange Online mailbox, so there is no calendar to write to."
    }.freeze

    attr_reader :status, :code

    def initialize(status, body)
      error = self.class.parse(body)
      @status = status
      @code = error["code"]
      super("Graph returned #{[status, @code].compact.join(' ')}: #{error['message'] || body.to_s[0, 300]}")
    end

    def user_message
      MESSAGES.fetch(code) { "Microsoft Graph refused the request (#{code || status})." }
    end

    def self.parse(body)
      parsed = JSON.parse(body.to_s)
      parsed.is_a?(Hash) && parsed["error"].is_a?(Hash) ? parsed["error"] : {}
    rescue JSON::ParserError
      {}
    end
  end

  private

  def raise_graph_error(status, headers, body)
    # ENTRA MIGRATION (API-4): Graph CAE / Conditional Access can also challenge the middle tier.
    claims = EntraAuth::ClaimsChallenge.parse(headers["www-authenticate"])
    raise EntraAuth::ClaimsChallengeRequired.new(claims, error: "graph_claims_challenge") if status == 401 && claims

    raise Error.new(status, body)
  end

  def perform(method, url, token, payload)
    uri = URI(url)
    request = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload) if payload
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) do |http|
      http.request(request)
    end
    [response.code.to_i, response.each_header.to_h, response.body]
  end
end
