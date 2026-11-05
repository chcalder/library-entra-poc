# frozen_string_literal: true

Rails.application.routes.draw do
  root "home#index"
  get "/healthz", to: proc { [200, { "content-type" => "text/plain" }, ["ok"]] }

  # Sign-in: CAS (before) and Entra via OmniAuth (after).
  # POST /auth/entra_id is handled by the OmniAuth middleware itself.
  # ENTRA MIGRATION (phase 2): the /auth/entra_id and /auth/failure routes are new.
  get "/login", to: "sessions#new", as: :login
  get "/cas/callback", to: "sessions#cas_callback"
  match "/auth/entra_id/callback", to: "sessions#entra_callback", via: %i[get post]
  get "/auth/failure", to: "sessions#failure"
  delete "/logout", to: "sessions#destroy", as: :logout

  get "/access-token", to: "home#access_token", as: :access_token # ENTRA MIGRATION (phase 2, demo)
  get "/graph-check", to: "home#graph_check", as: :graph_check # ENTRA MIGRATION (phase 2, API-3)
  get "/loans", to: "loans#index", as: :loans
  post "/loans/reminders", to: "loans#reminders", as: :loan_reminders
  get "/fines", to: "fines#index", as: :fines
  get "/eresources", to: "eresources#index", as: :eresources

  get "/staff", to: "staff#index", as: :staff
  post "/staff/patrons/:netid/fines/:fine_id/waive", to: "staff#waive_fine", as: :staff_waive_fine,
                                                     constraints: { netid: %r{[^/]+} }
end
