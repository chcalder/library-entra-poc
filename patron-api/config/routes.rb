# frozen_string_literal: true

Rails.application.routes.draw do
  get "/healthz", to: proc { [200, { "content-type" => "text/plain" }, ["ok"]] }

  scope "/api/v1", defaults: { format: :json } do
    get "me", to: "me#show"
    get "me/token", to: "me#token" # ENTRA MIGRATION (phase 2, demo): the access token as the API saw it
    get "me/graph-profile", to: "me#graph_profile" # ENTRA MIGRATION (phase 2, API-3): licence-free OBO check
    get "me/loans", to: "loans#index"
    post "me/loans/reminders", to: "loans#reminders"
    get "me/fines", to: "fines#index"
    get "me/eresources", to: "eresources#index"

    constraints netid: %r{[^/]+} do
      get "patrons/:netid", to: "patrons#show"
      post "patrons/:netid/fines/:fine_id/waive", to: "patrons#waive_fine"
    end

    get "notices/overdue", to: "notices#overdue"
  end
end
