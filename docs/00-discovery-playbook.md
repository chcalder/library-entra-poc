# Playbook 0 — Discovery: what has to change to move an application to Microsoft Entra ID

**Outcome:** a filled-in inventory for one application that says how it uses CAS and shared-secret API credentials
today, what has to change, and who has to be involved. Playbooks [1](01-auth-upgrade-playbook.md) (sign-in) and
[2](02-api-integration-playbook.md) (API integration) start from it.

---

## 1. Three sources, and what each can answer

No single source is enough. The code shows how the app depends on CAS; only the customer knows what is configured
around it; only the logs show what actually happens in production.

| Source | Answers | Can't answer |
|---|---|---|
| **The code** (Step 1) | Which CAS library or endpoints the app uses; which attributes it reads and what it does with them; whether NetID is the record key; where authorization decisions are made; every outbound call that sends an API key or username header; jobs and scripts; which settings exist | Deployed values; callers that live in other repos; whether Entra data matches CAS data; why a rule exists |
| **The customer** (Step 2) | CAS service registry and attribute release policy; how NetIDs, affiliations and groups are represented in Entra; who owns each API and each key; tenant permissions, licensing, Conditional Access; business reasons behind rules | Exactly where the code depends on any of it |
| **The logs** (Step 3) | Which services and callers are actually used, how often, by whom | Intent; anything that hasn't happened recently (annual jobs, term-start traffic) |

Scan the code **first**. It's cheap and repeatable, and it turns the customer conversation from an open survey into
specific questions ("your app reads `eduPersonAffiliation` and calls the bursar API with a username header; who owns
the bursar API?").

---

## 2. Procedure

### Step 1 — Scan the code

Run [`tools/discovery/scan.py`](../tools/discovery/scan.py) against each repository that is part of the application
(web app, APIs, jobs, infrastructure). It needs only Python 3.8+, reads files without running them, never reads `.env`
files, and redacts literal credentials it finds in snippets.

```bash
python3 tools/discovery/scan.py /path/to/app-repo -o discovery/scan-app.md
python3 tools/discovery/scan.py /path/to/app-repo --format json -o discovery/scan-app.json   # for tooling

# Options
#   --include-tests        also scan test/ and spec/ (useful: tests often document CAS behaviour)
#   --include-docs         also scan Markdown and text files
#   --exclude DIR          skip a directory (repeatable), e.g. vendored copies or unrelated tools
#   --max-per-file N       rows per file in the Markdown report (default 5; JSON always has everything)
```

The report has four parts:

1. **Summary**: hits per category and the playbook step each category feeds.
2. **Settings referenced**: identity- and credential-related environment variables. Each one needs a value per
   environment in the inventory, and most have an Entra replacement.
3. **Findings**: file and line for every match, with the code. Matches in comments are labelled `(comment)`.
4. **Questions the code raises**: one checklist item per category with findings, ready for Step 2.

What the categories mean:

| Category | What it looks for | Feeds |
|---|---|---|
| `CAS-LIB` | CAS client gems/packages (`rack-cas`, `omniauth-cas`, `rubycas-client`, `django-cas-ng`, phpCAS, Apereo Java client, …) or a hand-written client class | Playbook 1 · Step A |
| `CAS-PROTO` | `/cas/login`, `serviceValidate`, the CAS XML namespace, the `ticket` parameter, CAS URL settings | Playbook 1 · Step A.1 |
| `CAS-PROXY` | Proxy tickets (`pgtUrl`, `proxyValidate`) — the app calls back ends **as the user** | Playbook 1 · Step A.4 → Playbook 2 · Step F (OBO) |
| `CAS-OPTS` | `gateway` / `renew` | Playbook 1 · Step A.5 |
| `CAS-SLO` | Single logout handling | Playbook 1 · AUTH-6 |
| `WEB-AUTH` | `mod_auth_cas`, `REMOTE_USER` — sign-in enforced **outside** the app | Step 2 (config is not in the repo) |
| `OTHER-IDP` | SAML, Shibboleth, LDAP | Step 2 |
| `ATTR` | `eduPerson*`, `cas:user`, extra attributes, directory attribute names | Playbook 1 · Steps A.2, D |
| `ID-KEY` | NetID as a column, lookup key or route parameter | Playbook 1 · Step B (AUTH-3) |
| `AUTHZ` | Affiliation and role checks | Playbook 1 · Step D (AUTH-4) |
| `SESSION` | User in session, session store, timeouts | Playbook 1 · AUTH-5 |
| `SHARED-SECRET` | API keys, `X-Remote-User`-style headers, basic auth | Playbook 2 · Step A |
| `NETWORK-TRUST` | IP allowlists standing in for authentication | Playbook 2 · Step A |
| `HTTP-CLIENT` | Outbound HTTP calls (cross-check with `SHARED-SECRET`) | Playbook 2 · Step A |
| `JOBS` | Job frameworks, `app/jobs`, rake tasks, `bin/` scripts, cron | Playbook 2 · API-5 (client credentials) |
| `ENTRA-OIDC` | Existing Entra/OIDC/JWT code and libraries | Step 4 (how far along it already is) |

Read the findings, don't just count them. A pattern match says where to look; deciding what it means is the
engineer's job. Record conclusions in the inventory (Step 4), with file references.

**If the scan finds no CAS integration**, sign-in is probably enforced in front of the app (Apache `mod_auth_cas`,
an access gateway, a reverse proxy) and the app reads `REMOTE_USER` or a header. Ask for that configuration in Step 2.

To add a pattern (another library, a house-specific header), edit `CATEGORIES` in `scan.py` and add a case to
[`test_scan.py`](../tools/discovery/test_scan.py) (`python3 tools/discovery/test_scan.py`).

### Step 2 — Ask the customer

Send the **questions the code raises** from the scan report, plus the standing questionnaire below. Group them by who
can answer, and name the code finding behind each question so people know why it's being asked.

#### CAS administrators
1. Which CAS server and version runs in each environment? Which protocol does each of this app's registry entries use
   (CAS 2.0, CAS 3.0, SAML 1.1)?
2. Export the service registry entries for this app, for every environment (service URL patterns, attribute release,
   proxy policy, MFA policy, single-logout settings).
3. Which attributes are released to this app, and which system is the source of each (LDAP, SIS, HR, IdM)?
4. Which back-end services accept CAS proxy tickets from this app?
5. Is CAS enforced by a web server or proxy in front of the app? Share that configuration.
6. How long must the CAS registration stay active for rollback?

#### Identity / IAM team
1. How is the Entra tenant populated (Entra Connect / Cloud Sync from AD, an IdM product, manual)? Which populations
   are in it: students, faculty, staff, alumni, applicants, guests, sponsored accounts?
2. Does the UPN local part equal the NetID for **every** population? List exceptions (name changes, legacy accounts,
   alumni on a different domain, guests).
3. Is the NetID available as an Entra attribute (`onPremisesSamAccountName`, `employeeId`, an extension attribute)?
4. Have NetIDs ever been renamed or reassigned to a different person?
5. How are affiliations and entitlements represented in Entra today (groups, dynamic groups, extension attributes)?
   Who maintains them, and how quickly do changes propagate (e.g. a student graduating)?
6. Are there existing app registrations or enterprise apps for this application?

#### Application owner / development team
1. Confirm the scan findings: which are live code paths, which are dead?
2. Which environments exist (dev, test, staging, prod, DR), with their host names? Each needs a redirect URI.
3. What session and idle timeouts does policy require?
4. Which pages need step-up authentication (payments, grades, personal data)?
5. What other repositories belong to this application (jobs, shared libraries, infrastructure)?
6. How are configuration and secrets deployed (Key Vault, CI variables, files on servers)?

#### API and integration owners
1. List every caller of each API: other apps, jobs, integration platforms, vendor systems, scripts.
2. For each caller: credential type, where it is stored, who can rotate it, and when it last was.
3. Does the caller act **for a signed-in user** (sends a username) or **as itself**?
4. Which network allowlists are relied on?
5. Can each caller change its code, or is it a vendor product that only supports API keys? (Those may need a
   gateway or a longer dual-accept window.)

#### Tenant administrators and security
1. Is there a **non-production test tenant** (with an Azure subscription) where the project team can create app
   registrations, test users and consent grants? Without one, nothing past Phase 0 can be tested. Ask this first; it
   has the longest lead time.
2. Who can create app registrations, add API permissions and grant admin consent? What is the approval process?
3. Which Conditional Access policies apply to all apps, and which would apply to this one?
   Which **Azure Policy** assignments modify or deny resources in the target subscription (for example forcing Key
   Vault or storage to private-only)? These change what a deployment can do and are easy to miss.
4. Licensing: Entra ID P1/P2 (Conditional Access, authentication contexts), Exchange Online (Graph mail and
   calendar features) for each user population.
5. Rules for client credentials: secrets allowed? Maximum lifetime? Certificates or federated credentials required?
6. Logging and audit requirements (sign-in log retention, SIEM integration).

#### Business owners
1. Why does each authorization rule exist (policy, contract, vendor licence)? Does it still apply after the move?
2. Which user populations must keep access, and which can lose it (e.g. expired alumni)?
3. Change windows to avoid (term start, registration, exams, fiscal year end).

### Step 3 — Check the logs

Check the code and the answers from Step 2 against what actually happens in production. Use at least 30 days of
logs, and include a term start if possible.

| Log | Look for | Tells you |
|---|---|---|
| CAS server (service ticket validation, audit) | Service URLs validating tickets for this app; proxy-ticket requests; `renew`/`gateway` use | Which registry entries are live; hidden environments; real proxy use |
| API access logs, grouped by credential and source | Each distinct key, client IP and user agent | Callers nobody mentioned, especially vendor and script callers |
| Web server / proxy | `REMOTE_USER` and auth module activity | Whether sign-in really happens in front of the app |
| Entra sign-in logs (after Phase 2) | Sign-ins for the app registration; failures by error code | Users who didn't match a record; consent and assignment problems |
| The app's own logs during the dual-accept window | The `authenticated_via` label (`legacy` / `delegated` / `app`) | When it's safe to retire the API key ([Playbook 2, API-2](02-api-integration-playbook.md#api-2--dual-accept-window)) |

### Step 4 — Fill in the inventory

Copy the template in [section 3](#3-inventory-template) to the project's own space (one per application) and fill it
from Steps 1–3. Every row should cite its source: a file and line, a person, or a log query. Mark open items clearly.

`ENTRA-OIDC` findings tell you whether the app is already partly migrated. If it is, record which parts and which
app registrations exist before planning anything new.

### Step 5 — Decide and hand off

From the inventory, decide:

1. **Identifier strategy** ([Playbook 1, Step B](01-auth-upgrade-playbook.md#step-b--decide-the-identifier-strategy-pattern-auth-3)):
   UPN match, custom claim, and the crosswalk to `oid`.
2. **Attribute and role mapping** ([Playbook 1, Step D](01-auth-upgrade-playbook.md#step-d--map-attributes-to-claims-and-roles-pattern-auth-2-auth-4)).
3. **A flow for each caller** ([Playbook 2, section 2](02-api-integration-playbook.md#2-choose-the-right-flow)):
   delegated token, OBO, or client credentials, plus any caller that can't change.
4. **The phase plan:** which phase each component moves in, how long the dual-accept window lasts, and the rollback for
   each phase (see the README's migration phases).
5. **Blockers:** anything missing from Steps 2–3 that stops a phase (licensing, consent rights, data mismatches).

---

## 3. Inventory template

```markdown
# <Application> — Entra migration inventory
Scan: <link to scan report, date, commit>    Interviews: <names, dates>    Logs: <source, period>

## A. Application
| Component | Repo | Runtime / framework | Environments (host names) | Owner |

## B. Sign-in today (→ Playbook 1, Step A)
| Item | Value | Source |
| CAS server and version | | |
| Protocol / validate endpoint | | |
| Service registry entries (per environment) | | |
| Enforced by | app library / web server / proxy | |
| Proxy tickets used | yes/no; which back ends | |
| gateway / renew | | |
| Single logout | | |
| Session store and timeouts | | |

## C. Attributes (→ Playbook 1, Step D)
| CAS attribute | Used for (file:line) | Source system | Available in Entra as | Decision |

## D. Identifier (→ Playbook 1, Step B)
| Population | NetID = UPN local part? | NetID attribute in Entra | Exceptions | Decision |

## E. Authorization rules (→ Playbook 1, Step D / AUTH-4)
| Rule (file:line) | Based on | Business reason | Entra app role | Assigned via group |

## F. API callers (→ Playbook 2, Step A)
| API | Caller | Credential today | For a user or as itself | Can change code? | Target flow | Owner |

## G. Downstream calls made as the user (→ Playbook 2, Step F)
| From | To | How today (proxy ticket / header / none) | OBO scope needed | Consent |

## H. Settings
| Setting | Purpose | Per-environment values held in | Replaced by |

## I. Tenant and licensing
| Item | Status | Owner |
| App registration / consent rights | | |
| Conditional Access in scope | | |
| Entra ID P1 (auth context) | | |
| Exchange / M365 licences for Graph features | | |
| Credential policy (secret / certificate / federated) | | |

## J. Decisions, open questions and blockers
| # | Item | Owner | Due | Status |
```

---

## 4. Worked example: this repository

Running the scanner on this repo (`python3 tools/discovery/scan.py .`) finds what the playbooks describe:

| Category | Finds | Meaning for the plan |
|---|---|---|
| `CAS-LIB`, `CAS-PROTO` | The hand-written [`CasClient`](../portal/lib/cas_client.rb), its three `CAS_*_URL` settings, the callback reading `params[:ticket]` | One sign-in integration point, already behind `AUTH_MODE` |
| `CAS-PROXY`, `CAS-OPTS`, `CAS-SLO` | Nothing | No proxy tickets: the portal reaches the API with an API key instead (see `SHARED-SECRET`) |
| `ATTR` | `displayName`, `mail`, `eduPersonAffiliation` read in [`Identity.from_cas`](../portal/app/models/identity.rb) | Three attributes to map (Playbook 1, Step D) |
| `ID-KEY` | Patron records keyed by NetID throughout the API | Identifier strategy needed (Step B): UPN match + `oid` crosswalk |
| `AUTHZ` | `AFFILIATION_TO_ROLE`, `require_role!("Librarian")`, licence-restricted e-resources | Five app roles; the e-resources rule is a vendor licence term (a Step 2 question) |
| `SHARED-SECRET` | `X-Api-Key` + `X-Remote-User` from the portal; `X-Api-Key` alone from the notices job | Two callers: the portal acts **for a user** (→ delegated token), the job acts **as itself** (→ client credentials) |
| `HTTP-CLIENT` | Calls to CAS, the Patron API, Graph and Entra | Graph and Entra calls are the "after" code |
| `JOBS` | [`overdue_notices_job.rb`](../patron-api/lib/overdue_notices_job.rb), `bin/overdue_notices` | Client-credentials candidate (API-5) |
| `ENTRA-OIDC` | `omniauth-entra-id`, the `entra_auth` gem, bearer handling | The POC contains both states; a real "before" repo would show nothing here |

For a real application, use `--exclude` to leave out directories that aren't part of it. Here, for example, the mock CAS
server and the infrastructure scripts: `--exclude mock-cas --exclude infra`.
