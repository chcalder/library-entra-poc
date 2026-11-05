# Rails code changes for Microsoft Entra ID: a developer's guide

**Audience:** Ruby and Rails developers who know their application well and need to know exactly what changes when it
moves from CAS and shared API keys to Microsoft Entra ID.

**Scope:** every code and dependency change made in this POC, with the actual code, why each change is needed, and
what to watch for in your own application. The *procedures* (inventory, cut-over, rollback, validation) are in
[Playbook 1](01-auth-upgrade-playbook.md) (sign-in) and [Playbook 2](02-api-integration-playbook.md) (service to
service). Pattern IDs such as AUTH-3 and API-3 refer to those playbooks.

Every change in the code carries a marker comment. List them with:

```bash
grep -rn "ENTRA MIGRATION" portal patron-api gems
```

## The three scenarios

The guide is organized by the three scenarios a Rails application has to support. Each section stands on its own.

| # | Scenario | Before | After | Where in this POC |
|---|---|---|---|---|
| **1** | **Authentication**: a user signs in to the web app | CAS 3.0 ticket validation | OpenID Connect (authorization code flow) with Entra | Library Portal |
| **2** | **API calls**: an app calls your API | API key, plus an `X-Remote-User` header the API has to trust | An Entra access token the API validates: the **user's** token from a web app (delegated), or the **app's own** token from a job (client credentials) | Portal → Patron API, notices job → Patron API |
| **3** | **On-Behalf-Of (OBO)**: your API calls another API **as the user** | Not possible; the API never holds the user's identity | The API exchanges the user's token for a downstream token | Patron API → Microsoft Graph |

Scenarios build on each other: 2 needs the access token obtained in 1, and 3 needs the token validated in 2.

## Contents

- [Foundation (applies to every scenario)](#foundation-applies-to-every-scenario)
- [Scenario 1 — Authentication](#scenario-1--authentication)
- [Scenario 2 — API calls](#scenario-2--api-calls)
- [Scenario 3 — On-Behalf-Of](#scenario-3--on-behalf-of)
- [Testing the changes without Entra](#testing-the-changes-without-entra)
- [Checklist for your application](#checklist-for-your-application)

---

## Foundation (applies to every scenario)

### F.1 Versions and minimums

Built and tested with Ruby 3.3.13, Rails 8.0.5.2, Puma 8.0.2, Rack 3.2.8, omniauth 2.3.1, omniauth-entra-id 3.1.1,
omniauth-oauth2 1.10.0, oauth2 2.1.0, omniauth-rails_csrf_protection 1.0.2, jwt 3.3.0, json 2.21.2. The README lists
everything.

- **Ruby ≥ 3.1** for the shared `entra_auth` gem (`spec.required_ruby_version = ">= 3.1"`).
- **There is no Microsoft Authentication Library (MSAL) for Ruby.** Microsoft ships MSAL for .NET, Java, Python,
  JavaScript, Go and mobile platforms, but not Ruby. So:
  - **Scenario 1** uses the community `omniauth-entra-id` OmniAuth strategy (the successor to
    `omniauth-azure-activedirectory-v2`).
  - **Scenarios 2 and 3** (token validation, client credentials, refresh, OBO) use this repo's small
    [`entra_auth`](../gems/entra_auth) gem (F.3).

### F.2 One image, every phase: a configuration switch

Everything comes from environment variables, so the same build runs before or after (pattern AUTH-1). Rollback is a
configuration change, not a deploy of old code.

```ruby
# portal/lib/app_config.rb
# "cas" (before) or "entra" (after)
def auth_mode = ENV.fetch("AUTH_MODE", "cas")
def entra? = auth_mode == "entra"
def cas? = !entra?
```

| App | Switch | Other variables |
|---|---|---|
| Portal | `AUTH_MODE` = `cas` / `entra` | `ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID`, `ENTRA_CLIENT_SECRET`, `PATRON_API_SCOPES`, optional `PORTAL_BASE_URL` |
| API | `AUTH_MODE` = `legacy` / `both` / `entra` | `ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID`, `ENTRA_CLIENT_SECRET` (OBO only), `LEGACY_API_KEY`, optional `NETID_CLAIM`, `GRAPH_SCOPE` |
| Job | `AUTH_MODE` = `legacy` / `entra` | `ENTRA_TENANT_ID`, `JOB_CLIENT_ID`, `JOB_CLIENT_SECRET`, `PATRON_API_APP_SCOPE` |

### F.3 The shared token toolkit (`entra_auth`)

One small gem shared by the portal, the API and the job, so each app doesn't reimplement token handling. Everything
except `TokenValidator` uses only the standard library (`net/http`, `json`).

| Class | Purpose | Scenario |
|---|---|---|
| `Config` | One app registration: tenant, client ID, credential; token, JWKS and issuer URLs | all |
| `TokenEndpoint` | POST to `/oauth2/v2.0/token`; maps `claims` responses to `ClaimsChallengeRequired`, errors to `TokenError` | 2, 3 |
| `RefreshClient` | Renew the web app's access token | 2 |
| `TokenValidator` + `JwksProvider` | Validate incoming access tokens, with cached, rotating signing keys | 2 |
| `ClientCredentialsClient` | App-only tokens for jobs | 2 |
| `OboClient` | On-Behalf-Of exchange | 3 |
| `TokenCache` | In-memory, expiry-aware cache | 2, 3 |
| `ClaimsChallenge` | Parse and build `WWW-Authenticate` claims challenges | 2, 3 |
| `ManagedIdentityAssertion` | Use an Azure managed identity as a federated credential instead of a secret | all |

**Secretless credentials (API-7).** Every confidential client (portal, API, job) authenticates to Entra through
`Config`, which prefers a signed assertion over a secret:

```ruby
# Credentials, in order of preference for production:
#   1. client_assertion: a callable returning a signed assertion, e.g. a
#      managed identity token used as a federated identity credential (no
#      secret to store or rotate). See ManagedIdentityAssertion.
#   2. client_secret: simplest for a POC; keep it in Key Vault.
def client_credentials_form
  if client_assertion
    {
      client_id: client_id,
      client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      client_assertion: client_assertion.call
    }
  elsif client_secret && !client_secret.empty?
    { client_id: client_id, client_secret: client_secret }
  else
    raise Error, "No credential configured for client #{client_id}"
  end
end
```

Set `<PREFIX>USE_MANAGED_IDENTITY_FIC=true` and add a federated credential for the managed identity to the app
registration, and the secret disappears from configuration. To reuse the gem across apps, publish it to an internal
gem server or a git source rather than using `path:`.

---

## Scenario 1 — Authentication

**A user signs in to the web app.** CAS redirects and ticket validation are replaced by OpenID Connect's
authorization code flow. The app gets an **ID token** (who signed in) and, in the same round trip, an **access
token** for its API (used in Scenario 2).

### 1.1 What changes

| Change | Files |
|---|---|
| Add OmniAuth 2 and the Entra strategy; pin `json` | `portal/Gemfile` |
| Server-side session store | `portal/config/application.rb` |
| Mount OmniAuth behind `AUTH_MODE` | `portal/config/initializers/omniauth.rb` |
| Callback and failure routes | `portal/config/routes.rb` |
| Entra callback, failure and logout actions next to the CAS ones | `portal/app/controllers/sessions_controller.rb` |
| Sign-in button becomes a POST form | `portal/app/views/sessions/new.html.erb` |
| Map OIDC claims to your user model, plus `oid` | `portal/app/models/identity.rb` |
| Link NetID to `oid` | `patron-api/app/models/patron_store.rb` (via the authenticator) |

Controllers, views and models that use `current_identity` don't change.

**Registration needed:** a web app registration with a redirect URI per environment, a client secret (or
federated credential), delegated permissions `openid profile email offline_access` and your API's scopes, and admin
consent. See Playbook 1 Step C.

### 1.2 Dependencies

`portal/Gemfile`:

```ruby
gem "rexml"          # CAS XML parsing (not a default gem since Ruby 3.0)
gem "tzinfo-data"    # slim images ship without zoneinfo
# ENTRA MIGRATION (phase 2): the OIDC gems pull in faraday, which resolves json 3.x without this pin.
gem "json", "~> 2.7" # json 3.x drops the quirks_mode option ActiveSupport 8.0 passes, so every to_json raises

# ENTRA MIGRATION (phase 2, AUTH-1): the gems below are new.
# AFTER state: OpenID Connect sign-in with Microsoft Entra ID.
gem "omniauth", "~> 2.1"
gem "omniauth-entra-id", "~> 3.0"
gem "omniauth-rails_csrf_protection", "~> 1.0"

# Shared token toolkit (refresh, claims challenge parsing).
gem "entra_auth", path: "../gems/entra_auth"
```

- **OmniAuth 2.x is required.** OmniAuth 1.x let a GET start sign-in, which is a login-CSRF vulnerability
  (CVE-2015-9284). OmniAuth 2 is POST-only by default, and `omniauth-rails_csrf_protection` checks Rails' authenticity
  token on that POST. On OmniAuth 1, this is an upgrade in its own right.
- **Keep `rexml`** until CAS is decommissioned: both sign-in methods run during the migration.
- **Pin `json`** on Rails 8.0 (see 1.10).

### 1.3 Move sessions server-side

```ruby
# portal/config/application.rb
# Server-side sessions: Entra tokens are too large (and too sensitive)
# for the cookie store. memory_store suits one replica; use Redis
# (config.cache_store = :redis_cache_store) when running more than one.
config.cache_store = :memory_store, { size: 64.megabytes }
config.session_store :cache_store, key: "_library_portal", expire_after: 8.hours,
                                   same_site: :lax, secure: Rails.env.production?

config.filter_parameters += %i[token password ticket code client_secret]
```

- An access token plus a refresh token is typically 3–5 KB, which exceeds the 4 KB cookie limit. Even when it fits,
  an encrypted cookie still hands the browser a bearer credential.
- With more than one process or replica, use a **shared** store (Redis, or `activerecord-session_store`).
  Otherwise the OIDC `state` check fails on the callback.
- Filter `code` (the authorization code), `token` and `client_secret` out of logs.

### 1.4 Mount OmniAuth only in Entra mode

`portal/config/initializers/omniauth.rb` (abridged; 1.9 shows the rest):

```ruby
# Reads ENV directly (not AppConfig) because initializers run before the
# autoloader is ready for reloadable constants.
if ENV.fetch("AUTH_MODE", "cas") == "entra"
  require "omniauth/strategies/entra_id"

  module OmniAuth
    module Strategies
      # Step-up: when the Patron API (or Graph, via OBO) returned a claims
      # challenge, ApplicationController#step_up stores the claims in the
      # session; this adds them to THIS request's /authorize parameters.
      # Built per request (never written to the shared strategy options),
      # so one user's claims can't leak into another user's sign-in.
      class EntraIdStepUp < EntraId
        option :name, "entra_id" # keeps the /auth/entra_id paths

        def authorize_params
          super.tap do |params|
            claims = session[:pending_claims] || session["pending_claims"]
            params[:claims] = claims if claims.present?
          end
        end
      end
    end
  end

  OmniAuth.config.allowed_request_methods = [:post] # request phase is POST + CSRF token
  OmniAuth.config.full_host = ENV["PORTAL_BASE_URL"] if ENV["PORTAL_BASE_URL"].present?
  OmniAuth.config.logger = Rails.logger

  Rails.application.config.middleware.use OmniAuth::Builder do
    provider OmniAuth::Strategies::EntraIdStepUp,
             client_id: ENV.fetch("ENTRA_CLIENT_ID"),
             client_secret: ENV.fetch("ENTRA_CLIENT_SECRET"),
             tenant_id: ENV.fetch("ENTRA_TENANT_ID"),
             # One sign-in returns an ID token (who the user is) and an access
             # token for the Patron API (what the portal may call on their behalf).
             # offline_access adds a refresh token.
             scope: "openid profile email offline_access #{ENV.fetch('PATRON_API_SCOPES', '')}".strip
  end
end
```

- **One sign-in, two tokens.** Putting the API's scopes (`api://<api-id>/Patron.Read …`) in the sign-in `scope`
  returns an access token for the API alongside the ID token, with no second round trip. That's the hand-off to
  Scenario 2.
- **`tenant_id` is your tenant's GUID, not `common`.** With a specific tenant the strategy checks the ID token's
  issuer. With `common` any Entra tenant's users could sign in.
- **Subclass only if you need to.** It's needed here for per-request `claims` (step-up, AUTH-7). Never mutate the
  strategy's shared `options` per request; on a threaded server that leaks between users.

### 1.5 Routes

```ruby
# Sign-in: CAS (before) and Entra via OmniAuth (after).
# POST /auth/entra_id is handled by the OmniAuth middleware itself.
# ENTRA MIGRATION (phase 2): the /auth/entra_id and /auth/failure routes are new.
get "/login", to: "sessions#new", as: :login
get "/cas/callback", to: "sessions#cas_callback"
match "/auth/entra_id/callback", to: "sessions#entra_callback", via: %i[get post]
get "/auth/failure", to: "sessions#failure"
delete "/logout", to: "sessions#destroy", as: :logout
```

The callback path must match a **redirect URI registered on the app registration** exactly: scheme, host, port and
path. Register one per environment. A mismatch is `AADSTS50011`.

### 1.6 Sessions controller: both sign-in paths side by side

```ruby
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

  private

  def start_session(identity)
    return_to = session[:return_to]
    reset_session # prevent session fixation
    session[:identity] = identity.to_session
    yield if block_given?
    redirect_to local_path?(return_to) ? return_to : root_path
  end
end
```

- When `entra_callback` runs, OmniAuth has already checked `state`, redeemed the code with the client secret, and
  checked the ID token's issuer, audience and expiry. That's why Rails' CSRF check is skipped for that one action.
- `reset_session` before writing the identity prevents session fixation. Remember `return_to` first, and only
  redirect to local paths.
- `token_store.store(auth.credentials)` saves the access and refresh tokens for Scenario 2.

### 1.7 The sign-in page must POST

```erb
<%# ENTRA MIGRATION (phase 2, AUTH-1): rendered only in Entra mode; in CAS mode /login redirects to CAS. %>
<%# OmniAuth 2: the request phase must be a POST carrying the Rails CSRF token. %>
<%= button_to "Sign in with Microsoft", "/auth/entra_id", method: :post, class: "btn", data: { turbo: false } %>
```

`button_to` renders a form carrying the authenticity token. `data: { turbo: false }` stops Turbo from turning the
cross-origin redirect into a fetch, which fails silently. Search your views for `link_to ... "/auth/` and change
every one.

### 1.8 Map claims to your user (the attribute-mapping seam)

The rest of the app reads one `Identity`, wherever the user came from (AUTH-2):

```ruby
#   CAS attribute           Entra (OIDC) claim
#   ---------------------   --------------------------------------------
#   cas:user (NetID)        preferred_username local part (or a custom claim)
#   displayName             name
#   mail                    email (optional claim) / preferred_username
#   eduPersonAffiliation    app roles on the Patron API (read via /me, not here)
#   (none)                  oid: immutable object ID, the long-term key
Identity = Struct.new(:netid, :name, :email, :affiliations, :oid, :source, keyword_init: true) do
  def self.from_cas(result)
    attrs = result.attributes
    new(
      netid: result.user.downcase,
      name: attrs["displayName"]&.first || result.user,
      email: attrs["mail"]&.first,
      affiliations: attrs.fetch("eduPersonAffiliation", []),
      source: "cas"
    )
  end

  # ENTRA MIGRATION (phase 2, AUTH-2): the Entra side of the seam, mirroring from_cas.
  # auth: OmniAuth auth hash from the entra_id strategy.
  def self.from_entra(auth)
    data = auth.respond_to?(:to_hash) ? auth.to_hash : auth
    raw = data.dig("extra", "raw_info") || {}
    info = data["info"] || {}
    username = raw["preferred_username"] || info["email"].to_s
    new(
      netid: username.split("@").first.to_s.downcase,
      name: raw["name"] || info["name"] || username,
      email: raw["email"] || info["email"] || username,
      affiliations: [],
      oid: raw["oid"],
      source: "entra"
    )
  end
end
```

**Decisions to make for your app:**

- **What becomes the NetID.** Here it's the local part of `preferred_username` (`jstudent@contoso.edu` → `jstudent`).
  That only works when UPNs match NetIDs. Otherwise, sync the NetID into Entra (an extension attribute or
  `employeeId`) and emit it as an optional claim.
- **Store `oid`.** It's immutable and unique per user per tenant; UPNs and emails get renamed. Key new records on
  `oid` and keep the NetID for joins to existing data (1.10).
- **Affiliations aren't in the ID token.** They become app roles on the API, and the web app reads them from the API
  (Scenario 2, 2.5).

### 1.9 Read the ID token on its own

`omniauth-entra-id`'s `raw_info` decodes the ID token and **merges in the access token's claims**, and the access
token wins where both have a claim. So `from_entra` above is partly reading the API's access token, which a client
shouldn't do (API-8). It works only because both describe the same user. To get the ID token by itself, override
`extra` in the strategy subclass:

```ruby
# ENTRA MIGRATION (phase 2, demo): the ID token on its own. The gem's raw_info
# merges ID token and access token claims (access token wins), so it is not the
# ID token. The gem has already checked iss, aud, exp and nbf on this payload; the
# signature is not re-checked because the token came straight from the token
# endpoint over TLS (OIDC Core 3.1.3.7).
def extra
  header, payload = access_token.params["id_token"].to_s.split(".").first(2).map do |part|
    JSON.parse(Base64.urlsafe_decode64(part + "=" * (-part.length % 4)))
  end
  super.merge(id_token: { header: header, claims: payload })
rescue ArgumentError, JSON::ParserError
  super
end
```

**Recommendation:** have `Identity.from_entra` read `auth.extra.id_token[:claims]` instead of `raw_info`. The POC
still uses `raw_info`; this is a known follow-up.

### 1.10 Link the old identifier to the new one (crosswalk)

The first time a user arrives with an Entra token, record their `oid` next to their NetID (AUTH-3). In this POC the
API does it when it first sees the user's token (Scenario 2, 2.7):

```ruby
# ENTRA MIGRATION (phase 1, AUTH-3): new, with find_by_oid and the entra_oid field.
# Identifier crosswalk: the first time a patron arrives with an Entra token,
# record their immutable object ID next to the NetID. After cutover, look
# patrons up by oid so a renamed UPN can't attach to someone else's record.
def link_oid(netid, oid)
  @mutex.synchronize do
    patron = find!(netid)
    if patron[:entra_oid] && patron[:entra_oid] != oid
      raise NotFound, "NetID #{netid} is already linked to a different Entra account"
    end

    patron[:entra_oid] ||= oid
  end
end
```

In ActiveRecord terms: a migration adding a nullable, uniquely indexed `entra_oid` column to your users table, filled
on first Entra sign-in or in bulk from a directory export. Refuse a second `oid` for the same NetID.

### 1.11 Logout

```ruby
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
```

```ruby
def entra_logout_url(post_logout_redirect)
  authority = ENV.fetch("ENTRA_AUTHORITY", EntraAuth::DEFAULT_AUTHORITY).chomp("/")
  query = URI.encode_www_form(post_logout_redirect_uri: post_logout_redirect)
  "#{authority}/#{ENV.fetch('ENTRA_TENANT_ID')}/oauth2/v2.0/logout?#{query}"
end
```

Clearing the Rails session alone leaves the Entra session alive, so the next "Sign in" would be silent.

### 1.12 Authentication pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Sign-in page 500: `ArgumentError: unknown keyword: quirks_mode` | The OIDC gems pull in `faraday`, which resolved `json` 3.x. ActiveSupport 8.0 still passes `quirks_mode`, so every `to_json` fails. CAS pages never hit it, so it only appears when Entra mode is switched on | `gem "json", "~> 2.7"`, and install gems from the lockfile so a new release can't change the build between phases |
| `AADSTS50011` | Redirect URI mismatch | Register the exact callback URL for each environment |
| `csrf_detected` / `invalid_credentials` on the callback | `state` lost: the session isn't shared across processes or replicas, or cookies are blocked | Shared server-side session store; check `same_site` and the host name |
| "Sign in" button does nothing | Turbo intercepting the POST | `data: { turbo: false }` |
| OmniAuth warns on every sign-in about the `Host` header | Callback URL built from a forgeable header | `OmniAuth.config.full_host = ENV["PORTAL_BASE_URL"]` in production |
| Web app reads access token claims without meaning to | `raw_info` merges ID and access token claims | Read the ID token separately (1.9) |
| Users from other tenants can sign in | `tenant_id: "common"` | Use your tenant GUID |

---

## Scenario 2 — API calls

**An application calls your API with an Entra token instead of an API key.** There are two kinds of caller, and the
API must handle both:

| Caller | Token | How it's obtained | Identifies |
|---|---|---|---|
| **Web app, for a signed-in user** (delegated) | The user's access token: `scp` and the user's `roles` | At sign-in (Scenario 1), refreshed server-side | The user **and** the client app (`azp`) |
| **Background job, as itself** (app-only) | The app's own token: `roles`, no `scp`, `idtyp: app` | Client credentials | The app only |

The API stops trusting a header for "which user" and instead validates the token and reads the user from it.

### 2.1 What changes

| Side | Change | Files |
|---|---|---|
| Web app | Swap the API credential: API key → bearer token | `portal/lib/patron_api_client.rb`, `portal/app/controllers/application_controller.rb` |
| Web app | Keep tokens server-side, refresh before expiry | `portal/app/services/entra_token_store.rb` |
| Web app | Read roles from the API, map its errors | `application_controller.rb`, `patron_api_client.rb` |
| API | Accept both, then only Entra tokens (`legacy` → `both` → `entra`), log each caller | `patron-api/app/services/authenticator.rb`, `application_controller.rb` |
| API | Validate the JWT | `gems/entra_auth/lib/entra_auth/token_validator.rb` |
| API | Authorize with `scp` and `roles` | `patron-api/app/models/principal.rb`, `application_controller.rb` |
| Job | API key → client credentials | `patron-api/lib/overdue_notices_job.rb` |

**Registration needed:**
- An API registration: App ID URI `api://<id>`, **v2 access tokens**, delegated scopes, app roles for users and apps,
  and optional claim `idtyp`.
- The web app granted the scopes.
- A separate registration per job, granted an application permission.

All grants need admin consent. See Playbook 2 Step B.

### 2.2 Dependencies

`patron-api/Gemfile`:

```ruby
# ENTRA MIGRATION (phase 1): both gems below are new.
# Shared token toolkit (OBO, client credentials, token validation).
# The path is the same locally and in the container (/app -> /gems).
gem "entra_auth", path: "../gems/entra_auth"
gem "jwt", ">= 2.7", "< 4"
```

The API needs no OmniAuth: it never signs anyone in. Add `token assertion client_secret` to `filter_parameters`.
The web app needs nothing beyond Scenario 1's gems. The job uses `entra_auth` without Rails.

### 2.3 Web app: swap the credential, not the client

The API client was written so that only the credential object changes:

```ruby
# The portal's client for the Patron Record API. The only thing that changes
# in the migration is the credential object:
#
#   before: LegacyCredentials  -> X-Api-Key + X-Remote-User (API trusts the portal's word)
#   after:  BearerCredentials  -> Authorization: Bearer <user's access token for the Patron API>
class PatronApiClient
  LegacyCredentials = Struct.new(:api_key, :remote_user) do
    def apply(request)
      request["X-Api-Key"] = api_key
      request["X-Remote-User"] = remote_user if remote_user
    end
  end

  # ENTRA MIGRATION (phase 2): the AFTER credential.
  # token_provider is called per request so expired tokens get refreshed.
  BearerCredentials = Struct.new(:token_provider) do
    def apply(request)
      request["Authorization"] = "Bearer #{token_provider.call}"
    end
  end
end
```

The one place the web app chooses between them:

```ruby
# portal/app/controllers/application_controller.rb
# --- The one place the migration changes how the portal calls the API ---
# ENTRA MIGRATION (phase 2): bearer token in Entra mode, API key + NetID header before.
def patron_api
  @patron_api ||= PatronApiClient.new(base_url: AppConfig.patron_api_url, credentials: api_credentials)
end

def api_credentials
  if AppConfig.entra?
    PatronApiClient::BearerCredentials.new(-> { token_store.access_token })
  else
    PatronApiClient::LegacyCredentials.new(AppConfig.patron_api_key, current_identity&.netid)
  end
end
```

If your app builds `Faraday` or `Net::HTTP` requests in many places, consolidate them behind a client like this
first. That refactor is most of the work, and it's worth doing before Entra.

### 2.4 Web app: keep tokens server-side and refresh them

```ruby
# ENTRA MIGRATION (phase 2, AUTH-5): new file.
# Holds the portal's access token for the Patron API in the server-side
# session and refreshes it before it expires.
class EntraTokenStore
  class SessionExpired < StandardError; end

  KEY = "entra_tokens"

  # credentials: OmniAuth credentials (token, refresh_token, expires_at) or an EntraAuth::Token.
  def store(credentials)
    data = credentials.to_h.transform_keys(&:to_s)
    @session[KEY] = {
      "access_token" => data["token"] || data["access_token"],
      "refresh_token" => data["refresh_token"] || @session.dig(KEY, "refresh_token"),
      "expires_at" => (data["expires_at"] || @clock.call.to_i + 3000).to_i
    }
  end

  def access_token
    tokens = @session[KEY] or raise SessionExpired, "Not signed in with Entra"
    return tokens["access_token"] if tokens["expires_at"] - 60 > @clock.call.to_i

    refresh(tokens)
  end

  private

  def refresh(tokens)
    raise SessionExpired, "Access token expired and no refresh token is available" unless tokens["refresh_token"]

    token = @refresh_client.refresh(refresh_token: tokens["refresh_token"], scope: @scope)
    store(access_token: token.access_token, refresh_token: token.refresh_token, expires_at: token.expires_at.to_i)
    token.access_token
  rescue EntraAuth::ClaimsChallengeRequired => e
    # Conditional Access wants more (e.g. MFA): use the normal step-up page.
    raise PatronApiClient::ClaimsChallenge.new(e.claims, "Additional verification required")
  rescue EntraAuth::Error => e
    raise SessionExpired, "Token refresh failed: #{e.message}"
  end
end
```

- Access tokens last about 60–90 minutes; Rails sessions often last longer. Without refresh, users hit 401s
  mid-session. The 60-second margin avoids sending a token that expires in transit.
- Keep the **previous** refresh token if the response doesn't return a new one.
- A failed refresh ends the session cleanly instead of raising a 500:

```ruby
rescue_from PatronApiClient::Error, with: :api_error
rescue_from PatronApiClient::Forbidden, with: :forbidden
rescue_from PatronApiClient::Unauthorized, EntraTokenStore::SessionExpired, with: :session_expired
rescue_from PatronApiClient::ClaimsChallenge, with: :step_up
```

### 2.5 Web app: get roles from the API, map its errors

```ruby
# ENTRA MIGRATION (AUTH-4 + API-8): roles come from the API (/me), never from decoding the access token.
def api_roles
  session[:roles] ||= patron_api.me["roles"]
rescue PatronApiClient::Error, EntraTokenStore::SessionExpired
  []
end
```

The access token belongs to the API: its format can change, or it can be encrypted. The web app uses roles only to
show or hide links. The **API enforces them** (2.9).

```ruby
case status
when 200..299 then body
when 401
  claims = EntraAuth::ClaimsChallenge.parse(response["WWW-Authenticate"])
  raise ClaimsChallenge.new(claims, message) if claims

  raise Unauthorized.new(message, status: status)
when 403 then raise Forbidden.new(message, status: status)
when 501 then raise NotAvailable.new(message, status: status)
when 502 then raise DownstreamError.new(message, status: status)
else raise Error.new(message, status: status)
end
```

A 401 carrying a `claims` challenge means "send the user back to Entra with these claims" (MFA, an authentication
context, a revoked session). It does not mean "signed out" (API-4).

### 2.6 API: one authenticator, three modes

```ruby
# AUTH_MODE controls what the API accepts during migration:
#   legacy  API key only (the "before" state)
#   both    API key OR Entra bearer token (dual-accept window while clients move)
#   entra   Entra bearer tokens only (API key retired)
class Authenticator
  def call(headers)
    authorization = headers["Authorization"].to_s
    api_key = headers["X-Api-Key"].to_s

    # ENTRA MIGRATION (phase 1, API-2): a Bearer token takes the Entra path; the API-key
    # branch below is the pre-migration code, kept working until phase 3.
    if authorization.start_with?("Bearer ")
      entra(authorization.delete_prefix("Bearer ").strip)
    elsif !api_key.empty?
      legacy(api_key, headers["X-Remote-User"].to_s.strip)
    else
      raise Unauthenticated, "No credentials supplied"
    end
  end

  private

  # ENTRA MIGRATION (phase 1, API-1 + AUTH-3): validate the token (signature, issuer,
  # audience, expiry), build the caller from its claims, and link a user's oid to their NetID.
  def entra(token)
    raise Unauthenticated, "Bearer tokens are not accepted in legacy mode" if @mode == "legacy"

    claims = @validator.validate(token)
    principal = Principal.from_claims(claims, assertion: token, netid_claim: @netid_claim)
    @store.link_oid(principal.netid, principal.oid) if principal.delegated? && principal.netid
    principal
  end

  def legacy(api_key, remote_user)
    # ENTRA MIGRATION (phase 3): AUTH_MODE=entra retires the API key.
    raise Unauthenticated, "API keys are no longer accepted; use an Entra access token" if @mode == "entra"
    unless @legacy_api_key && OpenSSL.secure_compare(api_key, @legacy_api_key)
      raise Unauthenticated, "Invalid API key"
    end
    # ...
  end
end
```

Wire it into a `before_action`, and log every request. That log line is how you know when the key can be retired:

```ruby
class ApplicationController < ActionController::API
  before_action :authenticate!

  # ENTRA MIGRATION (phase 1, API-2): one line per authenticated request, so the dual-accept
  # window can be watched: the API key can be retired once no `legacy` lines remain.
  def authenticate!
    @principal = AppServices.authenticator.call(request.headers)
    Rails.logger.info({ authenticated_via: principal.kind, actor: principal.audit,
                        request: "#{request.method} #{request.path}" }.to_json)
  end
end
```

### 2.7 API: validate the token

```ruby
# Validates an incoming Entra v2.0 access token for THIS API:
#   signature (RS256, Entra JWKS), expiry/nbf, issuer = this tenant,
#   audience = this API's client ID (or its api:// URI), tid = this tenant.
class TokenValidator
  def initialize(config, audiences: nil, jwks: JwksProvider.new(config), leeway: 60)
    @config = config
    @audiences = audiences || [config.client_id, "api://#{config.client_id}"]
    @jwks = jwks
    @leeway = leeway
  end

  def validate(token)
    require "jwt"

    loader = lambda do |options|
      force = options[:kid_not_found] || options[:invalidate]
      JWT::JWK::Set.new(@jwks.keys(force: force))
    end

    payload, _header = JWT.decode(
      token, nil, true,
      algorithms: ["RS256"],
      jwks: loader,
      aud: @audiences, verify_aud: true,
      iss: @config.issuer, verify_iss: true,
      verify_iat: true,
      leeway: @leeway
    )

    raise InvalidToken, "token issued for another tenant" unless payload["tid"] == @config.tenant_id

    payload
  rescue JWT::DecodeError => e
    raise InvalidToken, e.message
  end
end
```

| Check | Without it |
|---|---|
| `algorithms: ["RS256"]` | `alg: none` or HMAC-confusion attacks |
| `jwks:` loader that refetches on an unknown `kid` | Entra rotates signing keys; every token would be rejected until a restart |
| `aud` = this API | Any valid token for any app in the tenant, a Graph token for example, would be accepted |
| `iss` = `https://login.microsoftonline.com/<tenant>/v2.0` | Tokens from other tenants. Needs `requestedAccessTokenVersion: 2` on the API registration, or tokens arrive with the v1 issuer `sts.windows.net` |
| `tid` | Defence in depth against multi-tenant mistakes |
| `leeway` | Clock skew between Entra and your servers |

Never use `JWT.decode(token, nil, false)` for authorization: it skips the signature check.

### 2.8 API: turn claims into a caller

```ruby
# :legacy     API key (+ optional X-Remote-User). The API trusts the caller's
#             word about which user it is acting for. This is what OBO replaces.
# :delegated  Entra access token with `scp`: a user signed in to a client app.
# :app        Entra access token with no `scp` (app-only, client credentials).
Principal = Struct.new(:kind, :netid, :oid, :name, :roles, :scopes, :acrs, :app_id, :assertion,
                       keyword_init: true) do
  # ENTRA MIGRATION (phase 1, API-1): the caller from a validated Entra token.
  # Pre-migration callers come from Principal.legacy below.
  def self.from_claims(claims, assertion:, netid_claim: "preferred_username")
    scopes = claims["scp"].to_s.split
    app_only = scopes.empty? || claims["idtyp"] == "app"
    new(
      kind: app_only ? :app : :delegated,
      netid: app_only ? nil : netid_from(claims[netid_claim]),
      oid: claims["oid"],
      name: claims["name"],
      roles: Array(claims["roles"]),
      scopes: scopes,
      acrs: Array(claims["acrs"]),
      app_id: claims["azp"] || claims["appid"],
      assertion: assertion
    )
  end
end
```

- **Delegated or app-only:** a user's token has `scp`. An app-only token has none, and with the optional claim
  `idtyp` configured it also says `idtyp: "app"`.
- **Keep the raw token** (`assertion`); Scenario 3 exchanges it.
- **`azp`** (v2) or **`appid`** (v1) is the calling application. Log it to see which clients are still on the key.

### 2.9 API: authorize with scopes and roles

```ruby
def require_user!
  forbid("This endpoint acts for a signed-in user") unless principal.user?
end

# ENTRA MIGRATION (phase 1, API-1): delegated tokens must carry the scope. Legacy API-key callers are fully
# trusted, which is exactly the weakness the migration removes.
def require_scope!(scope)
  forbid("Token is missing the #{scope} scope") if principal.delegated? && !principal.scope?(scope)
end

def require_role!(role)
  forbid("Requires the #{role} role") unless principal.role?(role)
end

# ENTRA MIGRATION (phase 1, API-5): app-only tokens need the application permission.
def require_app_role!(role)
  return if principal.legacy_service?
  return if principal.app? && principal.role?(role)

  forbid("Requires an app-only token with the #{role} application permission")
end
```

```ruby
# Staff endpoints: a Librarian, using a client that was granted Patron.Manage.
def staff_only!
  require_user! || require_scope!("Patron.Manage") || require_role!("Librarian")
end

# Batch endpoint: only an app holding Notices.Read.All.
def overdue
  return if require_app_role!("Notices.Read.All")
  # ...
end
```

- **`scp`** is what the *client app* may do for the user.
- **`roles`** is what the *user* (or, in an app-only token, the *app*) may do.
- A staff action needs both.
- User app roles replace directory affiliations such as `eduPersonAffiliation` (AUTH-4).

Return a proper 401 so OAuth clients understand it:

```ruby
rescue_from Authenticator::Unauthenticated, EntraAuth::InvalidToken do |e|
  response.headers["WWW-Authenticate"] = %(Bearer error="invalid_token", error_description="#{e.message.tr('"', "'")}")
  render json: { error: "unauthorized", message: e.message }, status: :unauthorized
end
```

### 2.10 Background jobs: client credentials

```ruby
# ENTRA MIGRATION (phase 2, API-5): the AUTH_MODE=entra branches in from_env and #headers.
class OverdueNoticesJob
  def self.from_env(env = ENV)
    mode = env.fetch("AUTH_MODE", "legacy")
    token_client = scope = nil
    if mode == "entra"
      token_client = EntraAuth::ClientCredentialsClient.new(EntraAuth::Config.from_env("JOB_", env: env))
      scope = env.fetch("PATRON_API_APP_SCOPE") # api://<patron-api-client-id>/.default
    end
    new(api_url: env.fetch("PATRON_API_URL"), mode: mode, api_key: env["LEGACY_API_KEY"],
        token_client: token_client, scope: scope)
  end

  private

  def headers
    if @mode == "entra"
      { "Authorization" => "Bearer #{@token_client.acquire(scope: @scope).access_token}" }
    else
      { "X-Api-Key" => @api_key.to_s }
    end
  end
end
```

```ruby
class ClientCredentialsClient
  def acquire(scope:)
    unless scope.end_with?("/.default")
      raise ArgumentError, "client credentials scope must be '<resource>/.default', got #{scope.inspect}"
    end

    @cache.fetch("cc:#{scope}") do
      @endpoint.request(grant_type: "client_credentials", scope: scope)
    end
  end
end
```

- **One app registration per job**, so the API's logs (`app_id`) and authorization (`roles`) can tell them apart.
  Sharing the web app's identity recreates the shared-key problem.
- **`.default` is mandatory** for client credentials: "every application permission an admin has granted this app
  on that API".
- Sidekiq, GoodJob and rake tasks follow the same pattern. Build the client once per process; the cache reuses the
  token until it nears expiry.

### 2.11 API call pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `iss` mismatch with `sts.windows.net` | API registration issuing v1 tokens | `requestedAccessTokenVersion: 2` on the **API** registration |
| Every token rejected after a while | Signing keys rotated and the JWKS cache never refreshes | Refetch on unknown `kid` (2.7) |
| Users get 401s an hour into a session | No refresh | `EntraTokenStore` (2.4) |
| A Graph token sent to the API fails "signature", not "audience" | Graph tokens carry a `nonce` and can only be validated by Graph | Expected. Prove the audience check with a properly signed token in a unit test |
| `AADSTS70011` from a job | Named scope instead of `.default` | `api://<api-id>/.default` |
| Job gets 403 "Requires an app-only token…" | Application permission not granted | Admin consent / app role assignment on the job's service principal |
| Can't tell when the key is safe to retire | Only some actions are logged | One log line per request with `authenticated_via` (2.6) |

---

## Scenario 3 — On-Behalf-Of

**Your API calls another API as the signed-in user.** The API exchanges the access token it received (Scenario 2)
for a token to the downstream API, still for the same user. With a NetID in a header this was impossible: the API
could never prove to Microsoft Graph, or any other Entra-protected API, who the user is.

```
Web app ──user's access token (aud = your API)──▶ Your API ──OBO exchange at Entra──▶ token (aud = Graph, same user)
                                                          └──────────────Bearer──────────────▶ Microsoft Graph
```

### 3.1 What changes

| Change | Files |
|---|---|
| The exchange | `gems/entra_auth/lib/entra_auth/obo_client.rb` |
| Controller helpers: require a user token, get a downstream token | `patron-api/app/controllers/application_controller.rb` |
| Downstream calls and error handling | `patron-api/app/services/graph_http.rb`, `graph_calendar.rb`, `graph_profile.rb` |
| Endpoints using it | `loans_controller.rb` (calendar), `me_controller.rb` (`graph-profile` check) |
| Pass claims challenges back to the browser | API `ApplicationController`, portal `ApplicationController#step_up`, the OmniAuth subclass (1.4) |

**Prerequisites. All three are required:**

- **The API's own credential.** The API becomes a confidential client: `ENTRA_CLIENT_SECRET`, or a federated
  credential (F.3). It isn't needed to *validate* tokens, only to exchange them.
- **Downstream permissions on the API's registration**, here Graph `User.Read` and `Calendars.ReadWrite`
  (delegated).
- **Admin consent for those permissions.** OBO can't show a consent prompt. Listing the web app under the API's
  `knownClientApplications` lets a user's consent cover both, but admin consent is simpler for an organization.

There are no new gems: OBO is a POST to the token endpoint.

### 3.2 The exchange

```ruby
# On-Behalf-Of: a middle-tier API exchanges the access token it received
# (whose audience is itself) for a token to a downstream API, still as the
# signed-in user.
#
# Rules that matter:
#   * user_assertion must be the raw incoming ACCESS token for this API,
#     never an ID token and never a token for another audience.
#   * One resource per request: Graph and the Patron API need separate calls.
#   * Cache per user (oid) + scope.
class OboClient
  GRANT_TYPE = "urn:ietf:params:oauth:grant-type:jwt-bearer"

  def acquire(user_assertion:, scope:, user_key:)
    raise ArgumentError, "user_key (the caller's oid) is required" if user_key.to_s.empty?

    @cache.fetch("obo:#{user_key}:#{scope}") do
      @endpoint.request(
        grant_type: GRANT_TYPE,
        assertion: user_assertion,
        scope: scope,
        requested_token_use: "on_behalf_of"
      )
    end
  end
end
```

The resulting POST to `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token`:

| Parameter | Value |
|---|---|
| `grant_type` | `urn:ietf:params:oauth:grant-type:jwt-bearer` |
| `assertion` | the incoming access token, exactly as received (`principal.assertion`) |
| `requested_token_use` | `on_behalf_of` |
| `scope` | `https://graph.microsoft.com/.default`: every Graph permission the API was consented for |
| `client_id` + `client_secret` (or `client_assertion`) | **the API's own** credentials |

**The cache key must include the user.** Keyed on scope alone, one user's Graph token would be handed to the next.

### 3.3 Using it in a controller

```ruby
# ENTRA MIGRATION (phase 2, API-3): Graph calls need the patron's own token to exchange.
def require_delegated!
  return if principal.delegated?

  render json: {
    error: "requires_delegated_identity",
    message: "Microsoft Graph calls need the patron's own Entra token. With an API key the Patron API " \
             "only has a NetID in a header, which Microsoft Graph cannot accept."
  }, status: :not_implemented
end

# ENTRA MIGRATION (phase 2, API-3 + API-6): exchange the caller's token (audience = this API)
# for a Graph token (audience = Graph), still as the caller. Cached per user and scope.
def obo_graph_token
  AppServices.obo.acquire(user_assertion: principal.assertion, scope: AppServices.graph_scope,
                          user_key: principal.oid)
end
```

```ruby
# POST /api/v1/me/loans/reminders
def reminders
  return if require_user! || require_scope!("Patron.Read") || require_delegated!

  graph_token = obo_graph_token
  upcoming = store.loans(principal.netid).reject { |l| l[:overdue] }
  created = upcoming.map do |loan|
    event = AppServices.graph_calendar.create_due_date_reminder(graph_token.access_token, loan)
    { loan_id: loan[:id], title: loan[:title], due_date: loan[:due_date], event_id: event["id"] }
  end
  # ...
end
```

API-key and app-only callers get a clear refusal (501 or 403): there's no user token to exchange.

### 3.4 Calling the downstream API and handling its errors

All Graph calls share one module, so every call reports Graph's reason rather than raising a 500:

```ruby
module GraphHttp
  BASE_URL = "https://graph.microsoft.com/v1.0"

  # Graph refused the call. `code` is Graph's own error code, so the API can
  # say why instead of failing with a 500.
  class Error < StandardError
    MESSAGES = {
      "MailboxNotEnabledForRESTAPI" => "Microsoft Graph accepted your identity, but your account has no " \
                                       "Exchange Online mailbox, so there is no calendar to write to."
    }.freeze
    # ...
  end

  private

  def raise_graph_error(status, headers, body)
    # ENTRA MIGRATION (API-4): Graph CAE / Conditional Access can also challenge the middle tier.
    claims = EntraAuth::ClaimsChallenge.parse(headers["www-authenticate"])
    raise EntraAuth::ClaimsChallengeRequired.new(claims, error: "graph_claims_challenge") if status == 401 && claims

    raise Error.new(status, body)
  end
end
```

Three failures, three handlers in the API's `ApplicationController`:

```ruby
rescue_from EntraAuth::TokenError do |e|                # the exchange itself failed (AADSTS…)
  Rails.logger.error("Token endpoint error: #{e.message}")
  message = e.consent_required? ? "Admin consent for the downstream API is missing" : "Downstream token request failed"
  render json: { error: "downstream_auth_failed", message: message }, status: :bad_gateway
end

rescue_from GraphHttp::Error do |e|                     # the exchange worked; Graph said no
  Rails.logger.error("Graph error: #{e.message}")
  render json: { error: "graph_error", graph_error: e.code, message: e.user_message }, status: :bad_gateway
end

rescue_from EntraAuth::ClaimsChallengeRequired do |e|   # MFA / Conditional Access: send it up to the browser
  challenge(e.claims, e.description || "Additional verification required")
end
```

Separating "the exchange failed" from "the downstream API refused" is what makes OBO debuggable:

- `AADSTS65001`: the API lacks admin consent for its Graph permissions.
- `MailboxNotEnabledForRESTAPI`: OBO worked, and the user simply has no mailbox.
- A claims challenge from the exchange or from Graph travels API (401 + `WWW-Authenticate`) → web app → browser →
  Entra, and the user completes the extra step (API-4, AUTH-7).

### 3.5 Prove OBO end to end, without a licence

`GET /api/v1/me/graph-profile` does the same exchange, then calls Graph `/me`. That needs only `User.Read` and works
for any Entra user:

```ruby
def graph_profile
  return if require_user! || require_scope!("Patron.Read") || require_delegated!

  graph_token = obo_graph_token
  me = AppServices.graph_profile.fetch(graph_token.access_token)
  render json: {
    graph_user: { id: me["id"], display_name: me["displayName"],
                  user_principal_name: me["userPrincipalName"], mail: me["mail"] },
    same_user: me["id"] == principal.oid,
    # From Entra's token response, not from decoding the Graph token (API-8).
    obo_scopes: graph_token.scope.to_s.split
    # ...
  }
end
```

`same_user: true` (Graph's `id` equals the caller's `oid`) proves the API acted **as the user**. Use the same trick
for any downstream API: a cheap "who am I" call is the best OBO smoke test. The portal's **Check On-Behalf-Of** page
shows it, with a table lining up the claims across the ID, access and OBO tokens:

| Claim | ID token | Access token (your API) | OBO token (Graph) |
|---|---|---|---|
| `oid`, `tid`, username | same user | same user | same user |
| `aud` | web app | your API | Graph |
| `azp` / `appid` (who holds it) | – | web app | **your API** |
| `scp` | – | your API's scopes | Graph scopes |

### 3.6 OBO pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `AADSTS65001` | The API has no admin consent for the downstream permissions | Grant consent on the API's enterprise app |
| `AADSTS50013` / assertion errors | Wrong token passed as the assertion: an ID token, an expired token, or a token for another audience | Pass the raw incoming access token for this API |
| `AADSTS7000215` | The API's client secret is wrong or expired | Use the secret value, not its ID; check expiry |
| Downstream call returns 500 | The downstream error wasn't rescued | Rescue it and return its error code (3.4) |
| One user sees another's data | OBO cache keyed without the user | Key on `oid` + scope |
| `interaction_required` + `claims` | MFA or Conditional Access required downstream | Expected: pass the claims challenge up (3.4) |
| Calendar write fails for test users | No Exchange Online mailbox (no licence) | Prove OBO with Graph `/me` (3.5) |

**Decoding tokens for display.** The demo pages show claims from the OBO token with `JWT.decode(token, nil, false)`.
That's acceptable only because nothing is decided from the result. Microsoft treats Graph tokens as opaque to their
holder, and they may become unreadable; the code shows nothing rather than fail.

---

## Testing the changes without Entra

Every class that talks to Entra or Graph takes an injectable `transport`, `endpoint`, `validator` or `clock`. The
tests are plain Ruby and Minitest: no Rails boot, no network, no tenant.

```ruby
# A fake validator: canned claims per token string.
class FakeValidator
  def initialize(tokens) = @tokens = tokens

  def validate(token)
    @tokens.fetch(token) { raise EntraAuth::InvalidToken, "bad signature" }
  end
end
```

```ruby
def test_creates_an_idempotent_event_with_the_obo_token
  seen = nil
  transport = lambda do |method, url, token, payload|
    seen = { method: method, url: url, token: token, payload: payload }
    [201, {}, '{"id":"evt-1"}']
  end
  event = GraphCalendar.new(time_zone: "Pacific Standard Time", transport: transport)
                       .create_due_date_reminder("graph-token", LOAN)

  assert_equal "evt-1", event["id"]
  assert_equal "https://graph.microsoft.com/v1.0/me/events", seen[:url]
  assert_equal "graph-token", seen[:token]
end
```

| Scenario | What's tested |
|---|---|
| 1 Authentication | CAS round trip against the mock, Entra claim → NetID mapping, token correlation |
| 2 API calls | Bearer vs legacy credentials; refresh and step-up; error mapping; authenticator in `legacy`/`both`/`entra`; token validation against a locally generated RSA key and JWKS (wrong audience, v1 issuer, expired, other tenant, `alg: none`); client credentials and `.default`; the crosswalk |
| 3 OBO | Request shape (`jwt-bearer`, `on_behalf_of`), caching per user and scope, consent errors, claims challenges, Graph calendar and profile calls, Graph error codes |

`./tools/check.sh` runs all of them inside the Docker images, then an end-to-end smoke test for the current phase.

---

## Checklist for your application

**Foundation**

- [ ] Ruby ≥ 3.1; a configuration switch (`AUTH_MODE`) per app; a token toolkit (or `entra_auth`) shared by all apps.

**Scenario 1 — Authentication**

- [ ] OmniAuth 2, `omniauth-entra-id`, `omniauth-rails_csrf_protection`; pin `json` on Rails 8.0.
- [ ] Shared server-side session store; `code`, `token` and `client_secret` filtered from logs.
- [ ] Initializer behind `AUTH_MODE`; tenant GUID, not `common`; `full_host` set in production.
- [ ] Redirect URI registered per environment; every sign-in link is a POST form with `turbo: false`.
- [ ] Callback calls `reset_session`, maps claims (from the ID token) to your user model, and stores tokens server-side.
- [ ] NetID source decided; `entra_oid` column added; crosswalk refuses a second `oid` per NetID.
- [ ] Logout clears the session and calls Entra's logout endpoint.

**Scenario 2 — API calls**

- [ ] Web app: one API client with a pluggable credential; your API's scopes requested at sign-in; bearer token sent;
      refreshed before expiry; `SessionExpired` and claims challenges handled; roles read from the API.
- [ ] API: `jwt`; validator checks signature (JWKS with rotation), `aud`, `iss` (v2), `tid` and expiry.
- [ ] API: `AUTH_MODE` `legacy` → `both` → `entra`; one log line per request with `authenticated_via` and `app_id`.
- [ ] API: `scp` for delegated calls, `roles` for users and apps; proper 401 `WWW-Authenticate` responses.
- [ ] Jobs: one registration each, an application permission granted by admin, `.default` scope.

**Scenario 3 — On-Behalf-Of**

- [ ] API credential (secret, certificate or federated credential); downstream permissions with admin consent.
- [ ] Exchange the raw incoming access token; cache per user and scope.
- [ ] Separate "exchange failed" (`TokenError`) from "downstream refused"; pass claims challenges up.
- [ ] A "who am I" call to prove OBO end to end.

**Production hardening (all scenarios)**

- [ ] Replace client secrets with certificates or federated credentials (managed identity).
- [ ] Redis (or similar) for sessions and token caches when scaling out.
- [ ] Install gems from the lockfile so builds are reproducible.
