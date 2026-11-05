# Playbook 1 — Upgrading sign-in from CAS to Microsoft Entra ID (OpenID Connect)

**Outcome:** a repeatable procedure, and the patterns behind it, for moving a Rails web app from CAS
to Entra ID sign-in without losing users' records or breaking authorization.
The Library Portal in this repo is the worked example; every step points at the code that implements it.

---

## 1. Before and after

| | Before (CAS) | After (Entra ID) |
|---|---|---|
| Protocol | CAS 3.0: browser redirect, service ticket, back-channel `serviceValidate` | OpenID Connect authorization-code flow |
| Rails code | Hand-rolled client: [`portal/lib/cas_client.rb`](../portal/lib/cas_client.rb) | OmniAuth + `omniauth-entra-id`: [`portal/config/initializers/omniauth.rb`](../portal/config/initializers/omniauth.rb) |
| User identifier | NetID (`cas:user`) | `oid` (immutable) + `preferred_username` (UPN) |
| Attributes | `displayName`, `mail`, `eduPersonAffiliation` released by the CAS attribute policy | ID token claims (`name`, `email`, `preferred_username`); affiliations become **app roles** |
| What the app gets for API calls | Nothing reusable: the app calls APIs with an API key and a NetID header | An **access token** for the Patron API (and a refresh token) |
| Step-up / MFA | Usually none per page | Conditional Access, including per-operation step-up via authentication context |
| Logout | CAS `/logout` ends the SSO session | Entra `/oauth2/v2.0/logout`, then the post-logout redirect |
| Switch in this repo | `AUTH_MODE=cas` | `AUTH_MODE=entra` |

The single most important difference is in the second-last row: **CAS authenticates the user; Entra authenticates the user
_and_ gives the app a token it can use to call APIs as that user.** That token is what makes Playbook 2 (OBO) possible.

---

## 2. Prerequisites

- An Entra tenant and an account that can create app registrations and grant admin consent.
  **Use a separate test tenant, not your organization's corporate tenant.** The setup script creates users, app
  roles and admin consent grants, which corporate tenants rarely allow, and corporate Conditional Access policies
  (e.g. token protection) can block the Azure CLI's Microsoft Graph calls outright (see `AADSTS530084` in
  [section 6](#6-common-errors)). A Microsoft 365 developer tenant or a sandbox tenant with its own Azure subscription
  works. Confirm this in Discovery ([Playbook 0](00-discovery-playbook.md), inventory section I) before planning dates.
- For the per-operation MFA demo: Entra ID P1 (Conditional Access + authentication contexts).
- For the Graph calendar feature: users with an Exchange Online mailbox (a licence). Unlicensed test users can sign in
  and see loans and fines, but calendar writes fail.
- Azure CLI and Python 3 (Azure Cloud Shell has both).

---

## 3. Procedure

### Step A — Inventory the CAS integration

[Playbook 0 — Discovery](00-discovery-playbook.md) is the full procedure: scan the code with
[`tools/discovery/scan.py`](../tools/discovery/scan.py), take the questions it raises to the customer, check them
against the logs, and fill in the inventory. Its section B covers this step. Record, per application:

1. **Service URL(s)** registered in the CAS service registry, and every environment's variant.
2. **Attributes released** to the service and **what the app does with each one**. Typical findings:
   NetID is the primary key for local records; `eduPersonAffiliation` drives authorization; `mail` is used for notices.
3. **Session handling:** where the app keeps the signed-in user, its timeout, and whether it honours CAS single logout.
4. **Back-end calls made "as the user":** API keys with a username header, CAS proxy tickets (`/proxyValidate`),
   shared service accounts. These are the inputs to Playbook 2.
5. **Gateways / renew:** use of `gateway=true` (silent check) or `renew=true` (force re-auth). Entra equivalents are
   `prompt=none` and `prompt=login` / `max_age`.

In this repo: [`mock-cas/users.yml`](../mock-cas/users.yml) shows the released attributes,
[`portal/app/models/identity.rb`](../portal/app/models/identity.rb) shows how they're used.

### Step B — Decide the identifier strategy (pattern AUTH-3)

Choose how an Entra user finds their existing record **before** writing code:

| Option | When it fits | Risk |
|---|---|---|
| UPN local part = NetID (`jstudent@univ.edu` → `jstudent`) | UPNs were provisioned from NetIDs | UPN renames (name changes) re-key the user |
| Custom claim carrying the NetID (directory extension, `employeeId`, `onPremisesSamAccountName`) | UPNs don't match NetIDs | Needs claims mapping policy or optional claim configuration |
| **Crosswalk to `oid`** (link on first sign-in, look up by `oid` afterwards) | Always, as the long-term key | Needs one-time linking logic |

This POC uses the first option for the initial match and then records `oid` (the crosswalk):
[`PatronStore#link_oid`](../patron-api/app/models/patron_store.rb). `NETID_CLAIM` lets you switch the claim
without code changes ([`Principal.from_claims`](../patron-api/app/models/principal.rb)).

> **Production warning: users whose UPN is not their NetID.** The UPN match works only where UPNs were provisioned
> from NetIDs. In this POC the four test users match (`jstudent@<domain>`), but any other account (yours, a guest, a
> renamed user) does not. The demo hides this with `DEMO_AUTO_PROVISION=true`, which gives an unmatched user a copy
> of `jstudent`'s record. **That setting must be off in production.** With it off, an unmatched user signs in to Entra
> but the API finds no patron record. Before cutover, measure how many users don't match (Discovery, inventory
> section D) and fix them: a NetID claim (`NETID_CLAIM`), a crosswalk loaded in advance, or a support process.

### Step C — Register the application in Entra

Run [`infra/entra/setup-app-registrations.sh`](../infra/entra/setup-app-registrations.sh), or do the equivalent in the portal.
Checklist for the web app registration (`<prefix>-portal`):

- [ ] Single tenant (`AzureADMyOrg`) unless guests from other tenants must sign in.
- [ ] Web platform redirect URI `https://<host>/auth/entra_id/callback` for **every** environment
      (`http://localhost` is allowed for local development; `deploy.sh` adds the Azure URL automatically).
- [ ] Client credential: secret for a POC (store in Key Vault); certificate or federated credential in production.
- [ ] Delegated permissions: `openid`, `profile`, `email`, `offline_access`, plus the API scopes it will call
      (`api://<patron-api>/Patron.Read`, `Patron.Manage`).
- [ ] Admin consent granted, so students never see a consent prompt.
- [ ] Optional: enterprise app → *Assignment required* = Yes to restrict sign-in to assigned users or groups.

Before running the script, check that `az account show` names the test tenant, that the signed-in account holds the
roles above, and that the output files are git-ignored (`git check-ignore .env infra/entra/test-users.txt`): both hold
secrets. In the POC we ran it as
`CREATE_TEST_USERS=true ASSIGN_ROLES_TO_ME="Student,Librarian" ./infra/entra/setup-app-registrations.sh`.

Then verify against the directory rather than the script output:

- [ ] API app: `identifierUris` is `api://<appId>`, `api.requestedAccessTokenVersion` is `2`, the scopes and app roles
      exist, and the portal is in `knownClientApplications`.
- [ ] `oauth2PermissionGrants` for each client service principal show `consentType` `AllPrincipals` (that is, admin
      consent): portal → Graph sign-in scopes, portal → `Patron.Read Patron.Manage`, Patron API → Graph `Calendars.ReadWrite User.Read`.
- [ ] `servicePrincipals/<api-sp>/appRoleAssignedTo` lists each user's roles and the job's `Notices.Read.All`.
      An extra assignment with an all-zeros role ID is Entra's "default access" entry, created by admin consent; it is harmless.
- [ ] `.env` has the IDs and three non-empty secrets, and is mode `600`.

### Step D — Map attributes to claims and roles (pattern AUTH-2, AUTH-4)

| CAS attribute | Entra source | Notes |
|---|---|---|
| `cas:user` (NetID) | `preferred_username` local part, or a custom claim | See Step B |
| `displayName` | `name` claim (needs `profile` scope) | |
| `mail` | `email` claim (needs `email` scope and a mail attribute) | Fall back to `preferred_username` |
| `eduPersonAffiliation` | **App roles** on the API registration (`Student`, `Faculty`, `Staff`, `Librarian`, `Alumni`), assigned to users or groups | Roles arrive in the API's access token `roles` claim |
| `eduPersonEntitlement` | App roles, or groups claim | Prefer app roles: groups claims hit the overage limit (200 groups) |
| _(none)_ | `oid`, `tid` | New: immutable user and tenant IDs |

Role assignment at scale: assign roles to **groups** fed by your identity management system (dynamic groups
on `extensionAttribute`/`employeeType`, or groups provisioned from the student system), not to individuals.
The mapping table lives in code as [`PatronStore::AFFILIATION_TO_ROLE`](../patron-api/app/models/patron_store.rb)
and in the setup script's test-user section.

### Step E — Change the code behind a switch (pattern AUTH-1)

1. **Introduce a normalized identity** that both sign-in paths produce:
   [`Identity.from_cas`](../portal/app/models/identity.rb) and `Identity.from_entra`. The rest of the app reads
   only `current_identity`.
2. **Add OmniAuth with the Entra strategy**, mounted only when `AUTH_MODE=entra`
   ([initializer](../portal/config/initializers/omniauth.rb)). Request the API scopes and `offline_access` in the
   same sign-in so the callback returns an access token and refresh token.
3. **Protect the request phase:** OmniAuth 2 requires `POST /auth/entra_id` with a CSRF token
   (`omniauth-rails_csrf_protection` gem; button in [`sessions/new`](../portal/app/views/sessions/new.html.erb)).
4. **Handle the callback** ([`SessionsController#entra_callback`](../portal/app/controllers/sessions_controller.rb)):
   reset the session (fixation), store the identity, store tokens server-side.
5. **Move sessions server-side** (pattern AUTH-5): `config.session_store :cache_store`
   ([application.rb](../portal/config/application.rb)). Tokens are too large and too sensitive for cookies.
6. **Replace logout:** redirect to the Entra logout endpoint with `post_logout_redirect_uri`
   ([`AppConfig.entra_logout_url`](../portal/lib/app_config.rb)).
7. **Refresh tokens** before expiry ([`EntraTokenStore`](../portal/app/services/entra_token_store.rb));
   a failed refresh ends the session cleanly.

### Step F — Test both modes side by side

The same build runs either way, so test the Entra path in a non-production environment while production stays on CAS.
Run the unit tests (see README) and the phase checks in [section 5](#5-validation-checklist).

### Step G — Cut over, with a rollback

1. Confirm the Patron API already accepts Entra tokens (Playbook 2, phase 1). Cutting over the portal first would break API calls.
2. Set `AUTH_MODE=entra` and deploy (`./infra/azure/deploy.sh 2`).
3. **Rollback** = set `AUTH_MODE=cas` and redeploy (`deploy.sh 1`). Keep the CAS service registration active until the
   rollback window closes.
4. Users' existing records keep working because of the identifier crosswalk.

### Step H — Decommission

Remove the CAS service registry entry, delete `cas_client.rb` and the CAS routes, and drop the `cas` branch of
`AUTH_MODE` once no rollback is needed.

---

## 4. Patterns

Each pattern is self-contained so it can be lifted into a coding-assistant skill or an architecture standard.

### AUTH-1 · Feature-flagged dual sign-in
- **Problem:** a big-bang cutover has no rollback and can't be tested in production-like conditions.
- **Pattern:** both sign-in paths live in the same build; one environment variable picks the active one.
  OmniAuth middleware is mounted only in Entra mode.
- **Code:** [`AppConfig.auth_mode`](../portal/lib/app_config.rb), [`SessionsController#new`](../portal/app/controllers/sessions_controller.rb).
- **Check:** flipping the variable and restarting is the entire cutover and the entire rollback.

### AUTH-2 · Normalized identity seam
- **Problem:** CAS attributes are read all over the codebase (`session[:cas_user]`, `session[:cas_extra_attributes]`).
- **Pattern:** one value object built from either protocol; nothing else touches protocol-specific data.
- **Code:** [`Identity`](../portal/app/models/identity.rb).
- **Check:** `grep -r "cas" app/` finds only the sessions controller and the identity builder.

### AUTH-3 · Identifier crosswalk (NetID → oid)
- **Problem:** local records are keyed by NetID; Entra's stable key is `oid`; UPNs can change.
- **Pattern:** match the first Entra sign-in by NetID (from UPN or a custom claim), record `oid` alongside, refuse to
  link a NetID to a second `oid`, and look up by `oid` after cutover.
- **Code:** [`PatronStore#link_oid`](../patron-api/app/models/patron_store.rb), called from
  [`Authenticator`](../patron-api/app/services/authenticator.rb).
- **Check:** renaming a test user's UPN after linking must not attach them to a different record.

### AUTH-4 · Affiliations become app roles, enforced by the API
- **Problem:** `eduPersonAffiliation` checks are scattered through the web app.
- **Pattern:** define app roles on the **API** registration; assign them to groups; the API authorizes on the
  `roles` claim; the web app asks the API what the user may do (`GET /api/v1/me`) instead of decoding tokens.
- **Code:** roles in the setup script; enforcement in [`EresourcesController`](../patron-api/app/controllers/eresources_controller.rb)
  and [`PatronsController`](../patron-api/app/controllers/patrons_controller.rb); display in [`HomeController`](../portal/app/controllers/home_controller.rb).
- **Check:** an Alumni user gets a 403 from the API for e-resources even if the portal shows the link.

### AUTH-5 · Server-side token session
- **Problem:** access + refresh tokens exceed the 4 KB cookie limit and must not reach the browser.
- **Pattern:** cache-backed session store; tokens in the session; Redis when running more than one replica.
- **Code:** [application.rb](../portal/config/application.rb), [`EntraTokenStore`](../portal/app/services/entra_token_store.rb).

### AUTH-6 · Logout
- **Problem:** CAS single logout and Entra logout behave differently.
- **Pattern:** clear the local session first, then redirect to the identity provider's logout with a registered
  post-logout URI. Set a front-channel logout URL on the app registration if other apps must end the portal session.
- **Code:** [`SessionsController#destroy`](../portal/app/controllers/sessions_controller.rb).

### AUTH-7 · Step-up with an authentication context
- **Problem:** fines and payments need MFA; course browsing doesn't.
- **Pattern:** create a Conditional Access authentication context (e.g. `c1`) with a policy requiring MFA. The API
  checks the `acrs` claim and, if missing, returns `401` with a claims challenge. The portal sends the user back to
  Entra with those claims and retries.
- **Code:** API [`require_auth_context!`](../patron-api/app/controllers/application_controller.rb);
  portal [`step_up`](../portal/app/controllers/application_controller.rb),
  [`step_up` view](../portal/app/views/sessions/step_up.html.erb), `EntraIdStepUp` strategy in the [OmniAuth initializer](../portal/config/initializers/omniauth.rb), which adds the claims to that request's `/authorize` parameters.
- **Setup:** Entra admin center → Protection → Conditional Access → Authentication contexts → add `c1`;
  create a policy targeting that context with *Require multifactor authentication*; set `FINES_AUTH_CONTEXT=c1`.

---

## 5. Validation checklist

| Check | CAS mode | Entra mode |
|---|---|---|
| Sign in as `jstudent` | Mock CAS form → home page shows NetID | Microsoft sign-in → home page shows NetID **and** Entra object ID |
| Home page "API saw this call as" | `legacy` from `legacy-api-key` | `delegated` from the portal's client ID |
| Return to deep link after sign-in (`/fines`) | ✓ | ✓ |
| Replayed CAS ticket / tampered `state` | Rejected (`INVALID_TICKET`) | Rejected by OmniAuth (`csrf_detected`) |
| Sign out, then open `/loans` | Redirected to sign-in | Redirected to sign-in |
| Token refresh after ~60 min idle-but-session-alive | n/a | Silent; no sign-in prompt |
| Fines with `FINES_AUTH_CONTEXT=c1` | No step-up (CAS has no equivalent) | "Additional verification required" → MFA → fines shown |

---

## 6. Common errors

| Error | Meaning | Fix |
|---|---|---|
| `AADSTS50011` | Redirect URI mismatch | Add the exact callback URL (scheme, host, port, path) to the app registration |
| `AADSTS65001` | Consent missing | Grant admin consent for the portal's permissions |
| `AADSTS7000215` | Invalid client secret | Use the secret **value**, not its ID; check expiry |
| `AADSTS700016` | Application not found in tenant | Wrong tenant ID or client ID |
| `AADSTS50105` | User not assigned | *Assignment required* is on: assign the user or a group |
| `AADSTS530084` from `az ad …` / `az rest` to Graph | A Conditional Access token-protection policy blocks the Azure CLI's Graph token (common in corporate tenants) | Use a test tenant (section 2). `deploy.sh` needs Graph only to add the redirect URI (phase 1+); the Entra setup script needs it throughout |
| `deploy.sh`: Key Vault `Forbidden` "Public network access is disabled" (older versions of this repo) | An Azure Policy (common in managed sandbox subscriptions) forces new vaults to private-only, so neither the deployer nor Container Apps can reach it | This repo now uses Container Apps secrets. To keep Key Vault, use a VNet-integrated environment with a private endpoint, or a policy exemption. Ask about such policies in Discovery |
| `AuthorizationFailed` from `deploy.sh` | No rights in the subscription; `main.bicep` also creates role assignments | Owner, or Contributor + User Access Administrator, on the subscription or resource group |
| Sign-in page 500, `ArgumentError: unknown keyword: quirks_mode` (Rails 8.0) | Adding the OIDC gems pulls in `faraday`, which resolved `json` to 3.x. ActiveSupport 8.0 still passes `quirks_mode`, so every `to_json` raises. CAS-only pages never hit it, so it appears only when Entra mode is switched on | Pin `gem "json", "~> 2.7"` in the Gemfile. Resolve gems from a committed lockfile so a new gem release can't change the build between phases |
| OmniAuth `csrf_detected` / `invalid_credentials` | State lost between request and callback | Session store not shared across replicas, or cookies blocked; check `same_site` and the host name |
| Portal 401 → sign-in loop | Patron API rejects the token | API not yet in `both`/`entra` mode, or `PATRON_API_SCOPES` doesn't name the API's `api://` URI |
