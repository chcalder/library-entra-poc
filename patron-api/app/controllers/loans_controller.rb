# frozen_string_literal: true

class LoansController < ApplicationController
  # GET /api/v1/me/loans
  def index
    return if require_user! || require_scope!("Patron.Read")

    render json: { loans: store.loans(principal.netid) }
  end

  # POST /api/v1/me/loans/reminders
  # ENTRA MIGRATION (phase 2, API-3): new endpoint, only possible after the migration.
  # On-Behalf-Of in action: exchange the patron's token (audience = this API)
  # for a Graph token (audience = Graph), still as the patron, then write to
  # the patron's own calendar.
  def reminders
    return if require_user! || require_scope!("Patron.Read") || require_delegated!

    graph_token = obo_graph_token
    upcoming = store.loans(principal.netid).reject { |l| l[:overdue] }
    created = upcoming.map do |loan|
      event = AppServices.graph_calendar.create_due_date_reminder(graph_token.access_token, loan)
      { loan_id: loan[:id], title: loan[:title], due_date: loan[:due_date], event_id: event["id"] }
    end

    audit("calendar_reminders_created", count: created.size)
    render json: { created: created }, status: :created
  end
end
