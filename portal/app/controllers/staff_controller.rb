# frozen_string_literal: true

# Librarian tools. Authorization is enforced by the Patron API (Librarian role
# + Patron.Manage scope); the portal only hides the link for other users.
class StaffController < ApplicationController
  def index
    @netid = params[:netid].to_s.strip.downcase
    @patron = patron_api.patron(@netid) if @netid.present?
  rescue PatronApiClient::Error => e
    raise if e.is_a?(PatronApiClient::ClaimsChallenge) || e.is_a?(PatronApiClient::Forbidden)

    flash.now[:alert] = e.message
  end

  def waive_fine
    fine = patron_api.waive_fine(params[:netid], params[:fine_id])["fine"]
    redirect_to staff_path(netid: params[:netid]), notice: "Waived #{fine['id']} ($#{format('%.2f', fine['amount'])})."
  end
end
