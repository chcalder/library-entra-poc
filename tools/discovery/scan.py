#!/usr/bin/env python3
"""Discovery scan for a CAS -> Microsoft Entra ID migration.

Finds the places in an application's source that depend on CAS sign-in or on
shared-secret API credentials, groups them by playbook step, and lists the
questions the code raises but cannot answer.

    python3 tools/discovery/scan.py <repo>                  # Markdown report to stdout
    python3 tools/discovery/scan.py <repo> -o scan.md
    python3 tools/discovery/scan.py <repo> --format json -o scan.json

Standard library only (Python 3.8+). Read-only: it never runs the target's code.
The procedure around it is docs/00-discovery-playbook.md.
"""

import argparse
import datetime
import json
import os
import re
import sys
from collections import OrderedDict

VERSION = "1.0"

# --- What to read -----------------------------------------------------------

SKIP_DIRS = {
    ".git", ".hg", ".svn", "node_modules", "vendor", "tmp", "log", "logs", "coverage",
    "dist", "build", "target", "bin/obj", "obj", ".bundle", ".venv", "venv", "__pycache__",
    "public/assets", "public/packs", ".terraform",
}
TEST_DIRS = {"test", "tests", "spec", "specs", "__tests__", "features"}
CODE_EXTS = {
    ".rb", ".erb", ".haml", ".slim", ".rake", ".ru", ".gemspec", ".py", ".js", ".mjs", ".cjs",
    ".ts", ".jsx", ".tsx", ".vue", ".java", ".kt", ".groovy", ".cs", ".vb", ".php", ".go",
    ".yml", ".yaml", ".json", ".xml", ".properties", ".ini", ".conf", ".cfg", ".config",
    ".toml", ".sh", ".bash", ".zsh", ".ps1", ".bicep", ".tf", ".html", ".htm", ".jsp", ".cshtml",
    ".htaccess",
}
CODE_NAMES = {
    "Gemfile", "Gemfile.lock", "Rakefile", "Dockerfile", "Procfile", "Jenkinsfile",
    ".env.example", ".env.sample", ".env.template", "crontab", ".htaccess",
}
LOCKFILES = {
    "Gemfile.lock", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "poetry.lock",
    "composer.lock", "Pipfile.lock", "packages.lock.json",
}
DOC_EXTS = {".md", ".markdown", ".rst", ".txt", ".adoc"}
MAX_BYTES = 1_000_000

# --- What to look for -------------------------------------------------------
#
# Each category: id, title, playbook step, why it matters, patterns (label, regex),
# optional path patterns (the file itself is the finding), and the questions that a
# hit raises for the customer. Patterns are case-insensitive; wrap a part in (?-i:...) to make it exact.


def _c(rx):
    return re.compile(rx, re.IGNORECASE)


CATEGORIES = [
    {
        "id": "CAS-LIB",
        "title": "CAS client libraries",
        "playbook": "Playbook 1 · Step A",
        "why": "Names the CAS integration style; a library usually means its config holds the service URL and attribute handling.",
        "lockfiles": True,
        "patterns": [
            ("CAS library", r"\b(rack-cas|omniauth-cas|rubycas-client|casclient|devise_cas_authenticatable|"
                            r"django-cas-ng|django_cas_ng|python-cas|flask-cas|phpcas|cas-client-core|"
                            r"cas-client-support|spring-security-cas|DotNetCasClient|passport-cas|connect-cas|"
                            r"cas-authentication|node-cas)\b"),
            ("CAS client class", r"\b(CasClient|CASClient|RubyCAS|phpCAS|Cas20ServiceTicketValidator|Cas30ServiceTicketValidator)\b"),
        ],
        "questions": [
            "Which CAS server version runs in each environment, and which protocol does this app's registry entry use (CAS 2.0, 3.0, SAML 1.1)?",
        ],
    },
    {
        "id": "CAS-PROTO",
        "title": "CAS protocol endpoints and tickets",
        "playbook": "Playbook 1 · Step A.1",
        "why": "Login, validation and logout URLs; each environment's variant must be in the CAS service registry today and becomes an Entra redirect URI.",
        "patterns": [
            ("validate endpoint", r"\b(p3/)?(serviceValidate|proxyValidate|samlValidate)\b"),
            ("CAS path", r"/cas/(login|logout|validate)\b"),
            ("CAS URL setting", r"\bcas[_-]?(login|logout|validate|server|base|host)[_-]?(url|uri)?\b"),
            ("CAS XML namespace", r"yale\.edu/tp/cas|cas:serviceResponse|authenticationSuccess"),
            ("service ticket param", r"params\[\s*[:\"']ticket[\"']?\s*\]|\.get\(\s*[\"']ticket[\"']|getParameter\(\s*\"ticket\""),
        ],
        "questions": [
            "List every service URL registered for this app in the CAS service registry, for every environment.",
        ],
    },
    {
        "id": "CAS-PROXY",
        "title": "CAS proxy tickets (calling back ends as the user)",
        "playbook": "Playbook 1 · Step A.4 → Playbook 2 · Step F",
        "why": "Each proxied back end is a candidate for On-Behalf-Of.",
        "patterns": [
            ("proxy granting ticket", r"\bpgt(Url|Iou|Id)\b|proxy[_-]?granting[_-]?ticket"),
            ("proxy ticket", r"\bproxy[_-]?ticket\b|/cas/proxy\b|proxyValidate"),
        ],
        "questions": [
            "Which back-end services accept CAS proxy tickets from this app? Each one is an On-Behalf-Of candidate.",
        ],
    },
    {
        "id": "CAS-OPTS",
        "title": "CAS gateway / renew",
        "playbook": "Playbook 1 · Step A.5",
        "why": "gateway maps to prompt=none, renew to prompt=login, max_age or an authentication context.",
        "patterns": [
            ("gateway", r"\bgateway\b\s*(=>|[:=])\s*(true|1|[\"']true)|[?&]gateway="),
            ("renew", r"\brenew\b\s*(=>|[:=])\s*(true|1|[\"']true)|[?&]renew="),
        ],
        "questions": [
            "Which pages rely on silent sign-in (gateway) or forced re-authentication (renew)?",
        ],
    },
    {
        "id": "CAS-SLO",
        "title": "Single logout",
        "playbook": "Playbook 1 · Step A.3, AUTH-6",
        "why": "CAS single logout and Entra front-channel logout behave differently.",
        "patterns": [
            ("SLO request", r"logoutRequest|SessionIndex"),
            ("single logout", r"single[_ -]?(sign[_ -]?out|log[_ -]?out)"),
        ],
        "questions": [
            "Is CAS single logout enabled for this service, and which other apps must end their sessions with it?",
        ],
    },
    {
        "id": "WEB-AUTH",
        "title": "Sign-in enforced outside the app (web server or proxy)",
        "playbook": "Playbook 0 · Step 2",
        "why": "With mod_auth_cas or a reverse proxy, the CAS config is not in this repo; the app only sees REMOTE_USER.",
        "patterns": [
            ("mod_auth_cas", r"mod_auth_cas|\bAuthType\s+CAS\b|\bCAS(LoginURL|ValidateURL|Attribute\w*)\b"),
            ("REMOTE_USER", r"(?-i:\bREMOTE_USER\b)|request\.remote_user|\.getRemoteUser\(\)"),
        ],
        "questions": [
            "Is CAS enforced by a web server or reverse proxy in front of the app? Its configuration is outside this repo; please share it.",
        ],
    },
    {
        "id": "OTHER-IDP",
        "title": "Other identity sources (SAML, Shibboleth, LDAP)",
        "playbook": "Playbook 0 · Step 2",
        "why": "Apps often read LDAP for attributes or groups after CAS sign-in; that dependency survives the move unless replaced.",
        "patterns": [
            ("SAML / Shibboleth", r"shibboleth|\bshib\b|ruby-saml|omniauth-saml|\bsaml\b"),
            ("LDAP", r"net-ldap|Net::LDAP|\bldaps?://|\bldap\b"),
        ],
        "questions": [
            "Does the app read LDAP (or another directory) directly for attributes or group membership? What replaces that in Entra (claims, groups, Graph)?",
        ],
    },
    {
        "id": "ATTR",
        "title": "Identity attributes the app reads",
        "playbook": "Playbook 1 · Step A.2, Step D",
        "why": "Each attribute needs an Entra source: an ID token claim, an app role, a group, or a Graph lookup.",
        "patterns": [
            ("eduPerson", r"\beduPerson\w+"),
            ("CAS user / attributes", r"cas:user|cas:attributes|\bcas_user\b|cas_extra_attributes|extra_attributes"),
            ("directory attribute", r"[\"':](displayName|givenName|employeeNumber|employeeType|isMemberOf|memberOf|ucsfEduIDNumber)[\"']?"),
        ],
        "questions": [
            "What is the CAS attribute release policy for this service, and which system is the source of each attribute (LDAP, SIS, HR)?",
            "Is each attribute available in Entra (synced attribute, extension attribute, or group)?",
        ],
    },
    {
        "id": "ID-KEY",
        "title": "NetID used as a record key",
        "playbook": "Playbook 1 · Step B (AUTH-3)",
        "why": "Decides the identifier strategy: UPN match, custom claim, and the crosswalk to oid.",
        "patterns": [
            ("netid", r"\bnet_?id\b"),
            ("lookup by username", r"find_by\(?\s*:?\s*(netid|net_id|uid|username|login)\b|where\(\s*(netid|uid|username|login):"),
            ("schema column", r"t\.(string|text)\s+[:\"'](netid|net_id|uid|username|login)\b|add_index.*\b(netid|uid|username)\b"),
        ],
        "questions": [
            "Do Entra UPNs match NetIDs for every population (students, staff, alumni, guests)? Have NetIDs ever been renamed or reassigned?",
            "Is the NetID synced to Entra (onPremisesSamAccountName, employeeId, or an extension attribute)?",
        ],
    },
    {
        "id": "AUTHZ",
        "title": "Authorization from affiliations or roles",
        "playbook": "Playbook 1 · Step D (AUTH-4)",
        "why": "These checks become app roles on the API registration, assigned to groups.",
        "patterns": [
            ("affiliation", r"affiliation"),
            ("role check", r"roles?\.include\?|has_role\?|require_(app_)?role!?|authorize!|\bcan\?\(|is_?in_?role|\bpundit\b|\bcancancan\b|\brolify\b"),
        ],
        "questions": [
            "Which groups or attributes feed each role today, and can the same source populate Entra groups for app-role assignment?",
            "Are any rules driven by licences or contracts (for example vendor e-resource terms)?",
        ],
    },
    {
        "id": "SESSION",
        "title": "Session handling",
        "playbook": "Playbook 1 · Step A.3 (AUTH-5)",
        "why": "Entra tokens are too large for cookie sessions; timeouts must match policy.",
        "patterns": [
            ("user in session", r"session\[\s*[:\"'](cas\w*|user\w*|netid|current_user\w*|uid)"),
            ("session store", r"session_store|\bexpire_after\b|session_timeout|timeout_in|reset_session"),
        ],
        "questions": [
            "What session and idle timeouts does policy require for this app?",
        ],
    },
    {
        "id": "SHARED-SECRET",
        "title": "Shared-secret API credentials (API keys, user headers, basic auth)",
        "playbook": "Playbook 2 · Step A",
        "why": "Each caller that sends a username header becomes a delegated or OBO caller; each that acts as itself gets client credentials.",
        "patterns": [
            ("API key", r"x-api-key|\bapi[_-]?key\b|HTTP_X_API_KEY"),
            ("user header", r"x-remote-user|x-forwarded-user|HTTP_X_REMOTE_USER|x-user-?id\b"),
            ("basic auth", r"basic_auth|http_basic|HTTPBasicAuth|[\"']Basic\s|Authorization:\s*Basic"),
            ("constant-time compare", r"secure_compare|compare_digest|timingSafeEqual"),
        ],
        "questions": [
            "Who holds each API key or shared credential, where is it stored, and how is it rotated?",
            "For each caller: does it act for a signed-in user (sends a username) or as itself?",
        ],
    },
    {
        "id": "NETWORK-TRUST",
        "title": "Network trust used as authentication",
        "playbook": "Playbook 2 · Step A",
        "why": "IP allowlists often hide callers that send no credential at all.",
        "patterns": [
            ("IP allowlist", r"ip[_-]?(allow|white)[_-]?list|allowed[_-]?ips|trusted[_-]?(ips|proxies|networks)"),
        ],
        "questions": [
            "Which network allowlists stand in for authentication, and which callers depend on them?",
        ],
    },
    {
        "id": "HTTP-CLIENT",
        "title": "Outbound HTTP calls",
        "playbook": "Playbook 2 · Step A",
        "why": "Every outbound integration needs an owner and a credential decision; cross-check against SHARED-SECRET.",
        "patterns": [
            ("HTTP client", r"Net::HTTP|\bFaraday\b|\bHTTParty\b|\bRestClient\b|\bTyphoeus\b|\bExcon\b|"
                            r"requests\.(get|post|put|patch|delete)\(|\baxios\b|HttpClient\b|WebClient\b|RestTemplate\b"),
        ],
        "questions": [
            "For each outbound integration, who owns the target service and how does it authenticate callers today?",
        ],
    },
    {
        "id": "JOBS",
        "title": "Scheduled jobs and non-interactive callers",
        "playbook": "Playbook 2 · Step E (API-5)",
        "why": "Jobs that call APIs move to client credentials with an application app role.",
        "patterns": [
            ("job framework", r"\bSidekiq\b|\bActiveJob\b|ApplicationJob|perform_later|perform_async|\bresque\b|delayed_job|good_job|solid_queue|\bwhenever\b|Clockwork|\bcron\b"),
        ],
        "paths": [
            ("job file", r"(^|/)(app/jobs/|lib/tasks/.*\.rake$|config/schedule\.rb$|[^/]*_job\.rb$|crontab$)"),
            ("script", r"(^|/)bin/[^/]+$"),
        ],
        "questions": [
            "Which scheduled jobs or external integrations call this app's APIs, and under which identity?",
        ],
    },
    {
        "id": "ENTRA-OIDC",
        "title": "Existing OAuth / OIDC / Entra code",
        "playbook": "Playbook 0 · Step 4",
        "why": "Shows how far a migration has already gone, and which libraries are already in use.",
        "lockfiles": True,
        "patterns": [
            ("Entra endpoint", r"login\.microsoftonline\.com|sts\.windows\.net|graph\.microsoft\.com"),
            ("OIDC library", r"omniauth-(entra-id|azure\w*|microsoft\w*|openid-connect)|openid_connect|\bmsal\b|\bpassport-azure-ad\b|Microsoft\.Identity\.Web"),
            ("bearer / JWT", r"\bBearer\b|JWT\.decode|\bjwt\b"),
        ],
        "questions": [
            "Is any part of this app already on Entra or another OIDC provider? Which app registrations exist, and who owns them?",
        ],
    },
]

for _cat in CATEGORIES:
    _cat["compiled"] = [(label, _c(rx)) for label, rx in _cat["patterns"]]
    _cat["compiled_paths"] = [(label, re.compile(rx)) for label, rx in _cat.get("paths", [])]

# Settings: environment variable names that look like identity or credential config.
SETTING_NAME = r"((?=[A-Z])[A-Z0-9_]*(?:CAS|SSO|AUTH|API_KEY|SECRET|TOKEN|PASSWORD|CLIENT_ID|TENANT|SCOPE|LDAP|SAML)[A-Z0-9_]*)"
SETTING_RX = re.compile(
    r"""(?:ENV(?:\.fetch)?\s*[\[(]\s*["']|os\.environ(?:\.get)?\s*[\[(]\s*["']|os\.getenv\(\s*["']|"""
    r"""process\.env\.|\$\{|Environment\.GetEnvironmentVariable\(\s*"|name:\s*["'])""" + SETTING_NAME
)
ENV_LINE_RX = re.compile(r"^\s*" + SETTING_NAME + r"\s*[:=]")

# Best-effort redaction of literal credentials in snippets.
SECRET_ASSIGN_RX = re.compile(
    r"""((?:secret|password|passwd|api[_-]?key|token|client[_-]?secret)\w*["']?\s*(?:=>|=|:)\s*)(["'])([^"'\s]{4,})\2""",
    re.IGNORECASE,
)
SECRET_BARE_RX = re.compile(
    r"""^(\s*[\w.-]*(?:secret|password|passwd|api[_-]?key|token)[\w.-]*\s*[:=]\s*)([^\s#"'$@{][^\s#]{3,})""",
    re.IGNORECASE,
)
COMMENT_RX = re.compile(r"^\s*(#|//|/\*|\*|<!--|<%#|--\s)")
BARE_SECRET_EXTS = {".yml", ".yaml", ".properties", ".ini", ".conf", ".cfg", ".env", ".example", ".sample", ".template", ".toml"}

# Standing list: what a scan can never answer (detail in docs/00-discovery-playbook.md).
CANNOT_TELL = [
    ("CAS administrators", "The service registry entries, attribute release policy, proxy permissions and single-logout settings actually deployed."),
    ("Identity team", "Whether Entra UPNs match NetIDs, whether NetIDs and affiliations are synced to Entra, and how guests and alumni are represented."),
    ("API owners", "Every caller that holds a key or relies on a network allowlist, including ones outside this repo."),
    ("Tenant administrators", "Who can create app registrations and grant consent; Conditional Access policies; Entra ID P1 and Exchange licensing."),
    ("Business owners", "Why each authorization rule exists (contracts, licences, policy) and whether it still applies after the move."),
    ("Logs", "Which integrations are actually used in production, as opposed to present in code."),
]


# --- Scanning ---------------------------------------------------------------

def is_test_path(rel):
    return any(part in TEST_DIRS for part in rel.split("/")[:-1])


def wanted(rel, name, include_docs):
    ext = os.path.splitext(name)[1].lower()
    if name in CODE_NAMES or ext in CODE_EXTS:
        return True
    if "/bin/" in "/" + rel and "." not in name:
        return True
    return include_docs and ext in DOC_EXTS


def is_secret_env(name):
    return name == ".env" or (name.startswith(".env.") and name not in CODE_NAMES)


def redact(line, name):
    line = SECRET_ASSIGN_RX.sub(lambda m: m.group(1) + m.group(2) + "[REDACTED]" + m.group(2), line)
    ext = os.path.splitext(name)[1].lower() or name.lower()
    if ext in BARE_SECRET_EXTS or name.startswith(".env"):
        line = SECRET_BARE_RX.sub(lambda m: m.group(1) + "[REDACTED]", line)
    return line


def scan(root, include_tests=False, include_docs=False, exclude=()):
    root = os.path.abspath(root)
    self_dir = os.path.dirname(os.path.abspath(__file__))
    findings = OrderedDict((c["id"], []) for c in CATEGORIES)
    settings = OrderedDict()
    stats = {"files_scanned": 0, "skipped": OrderedDict()}

    def skip(reason, rel):
        stats["skipped"].setdefault(reason, []).append(rel)

    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root).replace(os.sep, "/")
        rel_dir = "" if rel_dir == "." else rel_dir
        keep = []
        for d in sorted(dirnames):
            rel = (rel_dir + "/" + d).lstrip("/")
            if d in SKIP_DIRS or rel in SKIP_DIRS or any(rel == e or rel.startswith(e.rstrip("/") + "/") for e in exclude):
                continue
            if os.path.abspath(os.path.join(dirpath, d)) == self_dir:
                continue
            keep.append(d)
        dirnames[:] = keep

        for name in sorted(filenames):
            rel = (rel_dir + "/" + name).lstrip("/")
            path = os.path.join(dirpath, name)
            if is_secret_env(name):
                skip("may contain secrets (not read)", rel)
                continue
            if not wanted(rel, name, include_docs):
                continue
            if not include_tests and is_test_path(rel):
                skip("test code (use --include-tests)", rel)
                continue
            try:
                if os.path.getsize(path) > MAX_BYTES:
                    skip("larger than 1 MB", rel)
                    continue
                with open(path, "rb") as fh:
                    data = fh.read()
            except OSError as e:
                skip("unreadable: %s" % e.strerror, rel)
                continue
            if b"\0" in data[:8192]:
                skip("binary", rel)
                continue
            stats["files_scanned"] += 1
            text = data.decode("utf-8", errors="replace")
            lockfile = name in LOCKFILES

            for cat in CATEGORIES:
                for label, rx in cat["compiled_paths"]:
                    if rx.search(rel):
                        findings[cat["id"]].append({"file": rel, "line": 0, "match": label, "snippet": "(file)",
                                                    "comment": False})
                        break

            for lineno, line in enumerate(text.splitlines(), 1):
                for cat in CATEGORIES:
                    if lockfile and not cat.get("lockfiles"):
                        continue
                    for label, rx in cat["compiled"]:
                        if rx.search(line):
                            snippet = redact(line.strip(), name)
                            if len(snippet) > 160:
                                snippet = snippet[:157] + "..."
                            findings[cat["id"]].append({"file": rel, "line": lineno, "match": label, "snippet": snippet,
                                                        "comment": bool(COMMENT_RX.match(line))})
                            break
                if not lockfile:
                    for m in SETTING_RX.finditer(line):
                        settings.setdefault(m.group(1), set()).add(rel)
                    m = ENV_LINE_RX.match(line)
                    if m and (name.startswith(".env") or name.endswith((".yml", ".yaml"))):
                        settings.setdefault(m.group(1), set()).add(rel)

    return findings, settings, stats


def questions_for(findings):
    out = []
    for cat in CATEGORIES:
        if findings[cat["id"]]:
            for q in cat["questions"]:
                out.append((cat["id"], q))
    return out


# --- Reports ----------------------------------------------------------------

def md_cell(s):
    return s.replace("|", "\\|").replace("`", "'")


def files_of(hits):
    return sorted({h["file"] for h in hits})


def render_markdown(root, findings, settings, stats, max_per_category, max_per_file):
    name = os.path.basename(os.path.abspath(root))
    today = datetime.date.today().isoformat()
    lines = []
    w = lines.append
    w("# Discovery scan: %s" % name)
    w("")
    w("CAS → Microsoft Entra ID migration. Generated by `tools/discovery/scan.py` v%s on %s." % (VERSION, today))
    w("Procedure and questionnaire: [Playbook 0 — Discovery](docs/00-discovery-playbook.md).")
    w("")
    skipped_total = sum(len(v) for v in stats["skipped"].values())
    w("Scanned **%d** files; skipped %d." % (stats["files_scanned"], skipped_total))
    for reason, files in stats["skipped"].items():
        shown = ", ".join("`%s`" % f for f in files[:5]) + (" …" if len(files) > 5 else "")
        w("- %s: %d (%s)" % (reason, len(files), shown))
    w("")
    w("> Findings are leads, not conclusions: a pattern match shows where to look. Snippets are redacted on a")
    w("> best-effort basis; review the report before sharing it outside the project.")
    w("")

    w("## Summary")
    w("")
    w("| Category | Hits | Files | Feeds |")
    w("|---|---:|---:|---|")
    for cat in CATEGORIES:
        hits = findings[cat["id"]]
        label = "**%s** · %s" % (cat["id"], cat["title"])
        if hits:
            w("| %s | %d | %d | %s |" % (label, len(hits), len(files_of(hits)), cat["playbook"]))
        else:
            w("| %s | – | – | %s |" % (label, cat["playbook"]))
    w("")

    cas_hits = sum(len(findings[k]) for k in ("CAS-LIB", "CAS-PROTO", "CAS-PROXY", "WEB-AUTH"))
    if cas_hits == 0:
        w("> **No CAS integration found in the code.** Check whether sign-in is enforced by a web server or reverse")
        w("> proxy (mod_auth_cas, an access gateway) whose configuration lives outside this repo, or whether the app")
        w("> uses SAML/Shibboleth instead (see OTHER-IDP).")
        w("")

    w("## Settings referenced")
    w("")
    if settings:
        w("Identity- and credential-related settings. Each needs a value per environment in the inventory, and most")
        w("have an Entra replacement.")
        w("")
        w("| Setting | Where |")
        w("|---|---|")
        for key in sorted(settings):
            where = sorted(settings[key])
            shown = ", ".join("`%s`" % f for f in where[:4]) + (" …" if len(where) > 4 else "")
            w("| `%s` | %s |" % (key, shown))
    else:
        w("None found.")
    w("")

    w("## Findings")
    for cat in CATEGORIES:
        hits = findings[cat["id"]]
        if not hits:
            continue
        w("")
        w("### %s · %s" % (cat["id"], cat["title"]))
        w("")
        w("%s Feeds **%s**." % (cat["why"], cat["playbook"]))
        w("")
        w("| Location | Matched | Code |")
        w("|---|---|---|")
        shown = 0
        for f in files_of(hits):
            in_file = [h for h in hits if h["file"] == f]
            for h in in_file[:max_per_file]:
                if shown >= max_per_category:
                    break
                loc = h["file"] if h["line"] == 0 else "%s:%d" % (h["file"], h["line"])
                match = h["match"] + (" _(comment)_" if h["comment"] else "")
                w("| `%s` | %s | `%s` |" % (md_cell(loc), match, md_cell(h["snippet"])))
                shown += 1
            if len(in_file) > max_per_file and shown < max_per_category:
                w("| `%s` | … | _%d more in this file_ |" % (md_cell(f), len(in_file) - max_per_file))
        if shown < len(hits):
            w("")
            w("_%d hits not listed (raise `--max-per-file` / `--max-per-category`, or use `--format json`)._"
              % (len(hits) - shown))

    w("")
    w("## Questions the code raises")
    w("")
    qs = questions_for(findings)
    if qs:
        w("Take these to the customer (Playbook 0, Step 2). Each one comes from a category with findings above.")
        w("")
        for cid, q in qs:
            w("- [ ] **%s** %s" % (cid, q))
    else:
        w("None: no categories had findings.")
    w("")

    w("## What the code cannot tell you")
    w("")
    w("Always ask, whatever the scan found (full questionnaire in Playbook 0):")
    w("")
    for who, what in CANNOT_TELL:
        w("- **%s:** %s" % (who, what))
    w("")
    return "\n".join(lines)


def render_json(root, findings, settings, stats):
    return json.dumps({
        "tool": "tools/discovery/scan.py",
        "version": VERSION,
        "repo": os.path.abspath(root),
        "scanned_on": datetime.date.today().isoformat(),
        "files_scanned": stats["files_scanned"],
        "skipped": stats["skipped"],
        "categories": [
            {"id": c["id"], "title": c["title"], "playbook": c["playbook"], "why": c["why"],
             "hits": findings[c["id"]], "files": files_of(findings[c["id"]])}
            for c in CATEGORIES
        ],
        "settings": {k: sorted(v) for k, v in sorted(settings.items())},
        "questions": [{"category": cid, "question": q} for cid, q in questions_for(findings)],
        "cannot_tell_from_code": [{"ask": who, "about": what} for who, what in CANNOT_TELL],
    }, indent=2)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Scan an application repo for CAS and shared-secret API dependencies.")
    ap.add_argument("repo", help="path to the application repository")
    ap.add_argument("-o", "--output", help="write the report to this file instead of stdout")
    ap.add_argument("--format", choices=["md", "json"], default="md")
    ap.add_argument("--include-tests", action="store_true", help="also scan test/ and spec/ directories")
    ap.add_argument("--include-docs", action="store_true", help="also scan Markdown and text files")
    ap.add_argument("--exclude", action="append", default=[], metavar="DIR",
                    help="repo-relative directory to skip (repeatable)")
    ap.add_argument("--max-per-category", type=int, default=40, help="rows per category in the Markdown report")
    ap.add_argument("--max-per-file", type=int, default=5, help="rows per file within a category in the Markdown report")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.repo):
        ap.error("not a directory: %s" % args.repo)
    findings, settings, stats = scan(args.repo, args.include_tests, args.include_docs, tuple(args.exclude))
    if args.format == "json":
        report = render_json(args.repo, findings, settings, stats)
    else:
        report = render_markdown(args.repo, findings, settings, stats, args.max_per_category, args.max_per_file)

    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(report + "\n")
        total = sum(len(v) for v in findings.values())
        print("Wrote %s: %d findings in %d files scanned." % (args.output, total, stats["files_scanned"]), file=sys.stderr)
    else:
        sys.stdout.write(report + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
