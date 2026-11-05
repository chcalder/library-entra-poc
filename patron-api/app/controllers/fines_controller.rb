# frozen_string_literal: true

class FinesController < ApplicationController
  # GET /api/v1/me/fines
  # ENTRA MIGRATION (optional, AUTH-7): the require_auth_context! line.
  # Fines connect to the bursar, so they can require step-up MFA through a
  # Conditional Access authentication context (FINES_AUTH_CONTEXT, e.g. "c1").
  def index
    return if require_user! || require_scope!("Patron.Read")
    return if require_auth_context!(AppServices.fines_auth_context)

    fines = store.fines(principal.netid)
    render json: { fines: fines, balance: fines.select { |f| f[:status] == "open" }.sum { |f| f[:amount] }.round(2) }
  end
end
