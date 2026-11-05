# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "socket"
require "uri"

# The portal's client for the Patron Record API. The only thing that changes
# in the migration is the credential object:
#
#   before: LegacyCredentials  -> X-Api-Key + X-Remote-User (API trusts the portal's word)
#   after:  BearerCredentials  -> Authorization: Bearer <user's access token for the Patron API>
class PatronApiClient
  class Error < StandardError
    attr_reader :status

    def initialize(message, status: nil)
      @status = status
      super(message)
    end
  end
  class Unauthorized < Error; end
  class Forbidden < Error; end
  class NotAvailable < Error; end
  # ENTRA MIGRATION (phase 2, API-3): the API reached Entra or Graph, but they refused (e.g. no mailbox).
  class DownstreamError < Error; end

  # ENTRA MIGRATION (phase 2, API-4): raised from #handle when a 401 carries a claims challenge.
  class ClaimsChallenge < Error
    attr_reader :claims

    def initialize(claims, message)
      @claims = claims
      super(message, status: 401)
    end
  end

  LegacyCredentials = Struct.new(:api_key, :remote_user) do
    def apply(request)
      request["X-Api-Key"] = api_key
      request["X-Remote-User"] = remote_user if remote_user
    end
  end

  # ENTRA MIGRATION (phase 2): the AFTER credential.
  # token_provider is called per request so expired tokens get refreshed.
  BearerCredentials = Struct.new(:token_provider) do
    def apply(request)
      request["Authorization"] = "Bearer #{token_provider.call}"
    end
  end

  def initialize(base_url:, credentials:, transport: nil)
    @base_url = base_url.chomp("/")
    @credentials = credentials
    @transport = transport || method(:perform)
  end

  def me = get("/api/v1/me")
  def graph_profile = get("/api/v1/me/graph-profile")
  def access_token_seen_by_api = get("/api/v1/me/token")
  def loans = get("/api/v1/me/loans")
  def create_reminders = post("/api/v1/me/loans/reminders")
  def fines = get("/api/v1/me/fines")
  def eresources = get("/api/v1/me/eresources")
  def patron(netid) = get("/api/v1/patrons/#{escape(netid)}")
  def waive_fine(netid, fine_id) = post("/api/v1/patrons/#{escape(netid)}/fines/#{escape(fine_id)}/waive")

  private

  def get(path) = request(Net::HTTP::Get, path)
  def post(path) = request(Net::HTTP::Post, path)

  def request(klass, path)
    uri = URI("#{@base_url}#{path}")
    req = klass.new(uri)
    req["Accept"] = "application/json"
    req["Content-Type"] = "application/json" if klass == Net::HTTP::Post
    @credentials.apply(req)
    handle(@transport.call(uri, req))
  end

  def handle(response)
    status = response.code.to_i
    body = parse(response.body)
    message = body["message"] || "Patron API returned #{status}"
    case status
    when 200..299 then body
    when 401
      claims = EntraAuth::ClaimsChallenge.parse(response["WWW-Authenticate"])
      raise ClaimsChallenge.new(claims, message) if claims

      raise Unauthorized.new(message, status: status)
    when 403 then raise Forbidden.new(message, status: status)
    when 501 then raise NotAvailable.new(message, status: status)
    when 502 then raise DownstreamError.new(message, status: status)
    else raise Error.new(message, status: status)
    end
  end

  def parse(body)
    body.to_s.empty? ? {} : JSON.parse(body)
  rescue JSON::ParserError
    {}
  end

  def escape(value) = URI.encode_www_form_component(value.to_s)

  def perform(uri, request)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 30) do |http|
      http.request(request)
    end
  rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, SocketError => e
    raise Error.new("The Patron Record API is unreachable (#{e.class.name})", status: 502)
  end
end
