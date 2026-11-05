# frozen_string_literal: true

# ENTRA MIGRATION (phase 2, API-3): new file.
# A licence-free check of the OBO flow: read the signed-in user's own profile
# from Microsoft Graph (/me, needs only User.Read) with the OBO token. Every
# Entra user has a directory profile, so unlike the calendar this works without
# an Exchange Online mailbox. Graph answering with the caller's own object ID
# proves the Patron API acted AS the user, not as itself.
class GraphProfile
  include GraphHttp

  SELECT = "id,displayName,userPrincipalName,mail"

  def initialize(base_url: GraphHttp::BASE_URL, transport: nil)
    @base_url = base_url.chomp("/")
    @transport = transport || method(:perform)
  end

  def fetch(access_token)
    status, headers, body = @transport.call(:get, "#{@base_url}/me?$select=#{SELECT}", access_token, nil)
    return JSON.parse(body) if status == 200

    raise_graph_error(status, headers, body)
  end
end
