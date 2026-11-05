# frozen_string_literal: true

# ENTRA MIGRATION (phase 1, API-5): the API-key job still works until phase 3.
# Called by the overdue-notices batch job: no user is present, so the job uses
# the client credentials flow and an application permission (app role).
class NoticesController < ApplicationController
  # GET /api/v1/notices/overdue
  def overdue
    return if require_app_role!("Notices.Read.All")

    audit("overdue_notices_read")
    render json: { overdue: store.overdue_loans }
  end
end
