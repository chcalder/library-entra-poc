# frozen_string_literal: true

class EresourcesController < ApplicationController
  DATABASES = [
    { name: "JSTOR", url: "https://www.jstor.org" },
    { name: "Web of Science", url: "https://www.webofscience.com" },
    { name: "ProQuest Dissertations", url: "https://www.proquest.com" }
  ].freeze

  # GET /api/v1/me/eresources
  # Vendor licenses usually cover current students, faculty and staff only.
  # Role-based authorization: alumni can borrow print but not use databases.
  def index
    return if require_user! || require_scope!("Patron.Read")
    if (principal.roles & %w[Student Faculty Staff Librarian]).empty?
      return forbid("Licensed e-resources are limited to current students, faculty and staff")
    end

    render json: { databases: DATABASES }
  end
end
