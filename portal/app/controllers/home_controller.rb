# frozen_string_literal: true

class HomeController < ApplicationController
  skip_before_action :require_login, only: :index

  def index
    return unless signed_in?

    @profile = patron_api.me
    session[:roles] = @profile["roles"]
  end

  # ENTRA MIGRATION (phase 2, demo): the access token the portal sends to the API, as the
  # API decoded it. The portal itself never decodes access tokens (API-8).
  def access_token
    @token = patron_api.access_token_seen_by_api
  rescue PatronApiClient::NotAvailable => e
    @error = e.message
  end

  # ENTRA MIGRATION (phase 2, API-3): licence-free OBO check. The Patron API exchanges
  # the user's token for a Graph token and asks Graph who the user is.
  def graph_check
    @result = patron_api.graph_profile
    @correlation = TokenCorrelation.new(
      id_token: session.dig(:id_token, "claims"),
      access_token: @result.dig("incoming_token", "claims"),
      obo_token: @result.dig("obo_token", "claims"),
      graph_user: @result["graph_user"]
    )
  rescue PatronApiClient::NotAvailable, PatronApiClient::DownstreamError => e
    @error = e.message
  end
end
