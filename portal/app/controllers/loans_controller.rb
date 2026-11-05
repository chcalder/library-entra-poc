# frozen_string_literal: true

class LoansController < ApplicationController
  def index
    @loans = patron_api.loans["loans"]
  end

  # ENTRA MIGRATION (phase 2, API-3): new action.
  # The new Microsoft Graph capability. The portal only calls its own API;
  # the Patron API performs the OBO exchange and writes to the calendar.
  def reminders
    created = patron_api.create_reminders["created"]
    redirect_to loans_path, notice: "Added #{created.size} due-date reminder(s) to your Outlook calendar."
  rescue PatronApiClient::NotAvailable, PatronApiClient::DownstreamError => e
    redirect_to loans_path, alert: e.message
  end
end
