# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# ENTRA MIGRATION (phase 2, API-5): the AUTH_MODE=entra branches in from_env and #headers.
# Nightly batch job: fetch overdue loans from the Patron API and send notices.
# No user is signed in, so in Entra mode it uses the CLIENT CREDENTIALS flow:
# its own app registration, an application permission (Notices.Read.All)
# granted by an admin, and scope "api://<patron-api-client-id>/.default".
#
# Plain Ruby (no Rails) so it runs as a Container Apps Job from the same image.
class OverdueNoticesJob
  def initialize(api_url:, mode:, api_key: nil, token_client: nil, scope: nil, transport: nil, out: $stdout)
    @api_url = api_url.chomp("/")
    @mode = mode
    @api_key = api_key
    @token_client = token_client
    @scope = scope
    @transport = transport || method(:get)
    @out = out
  end

  def self.from_env(env = ENV)
    mode = env.fetch("AUTH_MODE", "legacy")
    token_client = scope = nil
    if mode == "entra"
      token_client = EntraAuth::ClientCredentialsClient.new(EntraAuth::Config.from_env("JOB_", env: env))
      scope = env.fetch("PATRON_API_APP_SCOPE") # api://<patron-api-client-id>/.default
    end
    new(api_url: env.fetch("PATRON_API_URL"), mode: mode, api_key: env["LEGACY_API_KEY"],
        token_client: token_client, scope: scope)
  end

  def run
    status, body = @transport.call("#{@api_url}/api/v1/notices/overdue", headers)
    raise "Patron API returned #{status}: #{body}" unless status == 200

    overdue = JSON.parse(body).fetch("overdue")
    overdue.each do |loan|
      # A real job would send email here (Azure Communication Services, or
      # Graph sendMail with an application permission scoped by an
      # Exchange application access policy).
      @out.puts "NOTICE to #{loan['email']}: \"#{loan['title']}\" was due #{loan['due_date']}"
    end
    @out.puts "#{overdue.size} overdue notice(s) prepared using #{@mode == 'entra' ? 'client credentials' : 'legacy API key'}"
    overdue.size
  end

  private

  def headers
    if @mode == "entra"
      { "Authorization" => "Bearer #{@token_client.acquire(scope: @scope).access_token}" }
    else
      { "X-Api-Key" => @api_key.to_s }
    end
  end

  def get(url, headers)
    uri = URI(url)
    request = Net::HTTP::Get.new(uri)
    headers.each { |k, v| request[k] = v }
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |h| h.request(request) }
    [response.code.to_i, response.body]
  end
end
