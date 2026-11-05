# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_before_action :require_login
  # ENTRA MIGRATION (phase 2): OmniAuth validates `state` on the callback; Rails CSRF does not apply there.
  skip_forgery_protection only: :entra_callback

  # GET /login
  def new
    return redirect_to root_path if signed_in?

    session[:return_to] = params[:return_to] if local_path?(params[:return_to])

    if AppConfig.cas?
      # BEFORE: bounce the browser to CAS; it comes back to /cas/callback?ticket=ST-...
      redirect_to AppConfig.cas_client.login_url(service: cas_service_url), allow_other_host: true
    end
    # ENTRA MIGRATION (phase 2, AUTH-1) AFTER: render a page whose button POSTs to
    # /auth/entra_id (OmniAuth request phase).
  end

  # GET /cas/callback?ticket=ST-...
  def cas_callback
    result = AppConfig.cas_client.validate(ticket: params[:ticket], service: cas_service_url)
    start_session(Identity.from_cas(result))
  rescue CasClient::ValidationError => e
    @message = "CAS sign-in failed (#{e.message})"
    render "shared/error", status: :unauthorized
  end

  # ENTRA MIGRATION (phase 2, AUTH-2 + AUTH-5): entra_callback and failure are new.
  # GET /auth/entra_id/callback  (OmniAuth has exchanged the code for tokens)
  def entra_callback
    auth = request.env["omniauth.auth"]
    start_session(Identity.from_entra(auth)) do
      token_store.store(auth.credentials)
      # Header and claims only, for display on Home; the ID token itself is never kept or sent anywhere.
      session[:id_token] = auth.extra.id_token.to_h
    end
  end

  # GET /auth/failure
  def failure
    @message = "Microsoft Entra sign-in failed: #{params[:message].to_s.humanize}"
    render "shared/error", status: :unauthorized
  end

  # DELETE /logout
  # ENTRA MIGRATION (phase 2, AUTH-6): Entra sign-out endpoint instead of CAS logout.
  def destroy
    reset_session
    url = if AppConfig.entra?
            AppConfig.entra_logout_url(root_url)
          else
            AppConfig.cas_client.logout_url(service: root_url)
          end
    redirect_to url, allow_other_host: true
  end

  private

  # The service URL must be byte-identical at login and at validation.
  def cas_service_url = "#{request.base_url}/cas/callback"

  def start_session(identity)
    return_to = session[:return_to]
    reset_session # prevent session fixation
    session[:identity] = identity.to_session
    yield if block_given?
    redirect_to local_path?(return_to) ? return_to : root_path
  end

  def local_path?(path)
    path.is_a?(String) && path.start_with?("/") && !path.start_with?("//")
  end
end
