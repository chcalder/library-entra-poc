# frozen_string_literal: true

class MeController < ApplicationController
  # GET /api/v1/me
  # ENTRA MIGRATION (phase 1, API-8): authenticated_via and calling_app are new.
  # The portal shows roles from here instead of reading the access token:
  # access tokens belong to the API, clients treat them as opaque.
  def show
    return if require_user! || require_scope!("Patron.Read")

    render json: store.profile(principal.netid).merge(
      roles: principal.roles,
      authenticated_via: principal.kind,
      calling_app: principal.app_id
    )
  end

  # GET /api/v1/me/token
  # ENTRA MIGRATION (phase 2, demo): the access token this request arrived with, after the
  # authenticator validated it. The API is the token's audience, so it may read it; the
  # portal may not (API-8), which is why the portal asks the API instead of decoding it.
  def token
    return if require_user! || require_delegated!

    render json: decode_for_display(principal.assertion)
  end

  # GET /api/v1/me/graph-profile
  # ENTRA MIGRATION (phase 2, API-3): new endpoint, a licence-free OBO check. The same
  # exchange as calendar reminders, then Graph /me, which needs no mailbox.
  def graph_profile
    return if require_user! || require_scope!("Patron.Read") || require_delegated!

    graph_token = obo_graph_token
    me = AppServices.graph_profile.fetch(graph_token.access_token)
    render json: {
      graph_user: { id: me["id"], display_name: me["displayName"],
                    user_principal_name: me["userPrincipalName"], mail: me["mail"] },
      same_user: me["id"] == principal.oid,
      # From Entra's token response, not from decoding the Graph token (API-8).
      obo_scopes: graph_token.scope.to_s.split,
      # Demo only: both sides of the exchange, so the portal can show how they correlate.
      incoming_token: decode_for_display(principal.assertion),
      obo_token: decode_for_display(graph_token.access_token)
    }
  end

  private

  # ENTRA MIGRATION (phase 2, demo): a token's header and claims, for display only. Nothing
  # here relies on them. Graph tokens are not meant to be read by their holder and may become
  # opaque, so return nil rather than fail.
  def decode_for_display(token)
    claims, header = JWT.decode(token, nil, false)
    { header: header, claims: claims }
  rescue JWT::DecodeError
    nil
  end
end
