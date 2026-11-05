# frozen_string_literal: true

# Staff operations. The audit log records the librarian who acted (from the
# OBO-style delegated token), not a shared service account.
class PatronsController < ApplicationController
  # GET /api/v1/patrons/:netid
  def show
    return if staff_only!

    netid = params[:netid]
    render json: store.profile(netid).merge(loans: store.loans(netid), fines: store.fines(netid))
  end

  # POST /api/v1/patrons/:netid/fines/:fine_id/waive
  def waive_fine
    return if staff_only!

    fine = store.waive_fine!(params[:netid], params[:fine_id])
    audit("fine_waived", patron: params[:netid], fine_id: fine[:id], amount: fine[:amount])
    render json: { fine: fine }
  end

  private

  # ENTRA MIGRATION (phase 1, AUTH-4): the Librarian app role from Entra replaces the
  # eduPersonAffiliation lookup, and delegated tokens also need the admin-only Patron.Manage scope.
  def staff_only!
    require_user! || require_scope!("Patron.Manage") || require_role!("Librarian")
  end
end
