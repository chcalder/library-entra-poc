#!/usr/bin/env python3
"""End-to-end smoke test for the Library POC, local or deployed.

Drives the portal the way a browser does (CAS sign-in, pages, forms) and, when it can
reach it, calls the Patron API directly. Expected results depend on the migration phase,
following the validation tables in docs/01 (section 5) and docs/02 (section 5).

    python3 tools/smoke/smoke_test.py --phase 0                       # local docker compose
    python3 tools/smoke/smoke_test.py --phase 0 --portal https://<portal-fqdn> --no-api   # Azure
    python3 tools/smoke/smoke_test.py --phase 0 --mutate              # also waive a fine

The API key is read from LEGACY_API_KEY (environment, then .env at the repo root).
Exit status is 0 only if every check passed. Standard library only (Python 3.8+).
"""

import argparse
import html
import http.cookiejar
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PASSWORD = "password"  # mock CAS demo password


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Browser:
    """A cookie-keeping client that does not follow redirects, so each hop can be checked."""

    def __init__(self):
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar), NoRedirect)

    def request(self, method, url, data=None, headers=None):
        body = urllib.parse.urlencode(data).encode() if isinstance(data, dict) else data
        req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
        try:
            with self.opener.open(req, timeout=30) as resp:
                return resp.status, resp.headers, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read().decode("utf-8", "replace")

    def get(self, url, **kw):
        return self.request("GET", url, **kw)

    def post(self, url, data, **kw):
        return self.request("POST", url, data=data, **kw)


def text_of(page):
    page = re.sub(r"(?s)<(style|script|head)[^>]*>.*?</\1>", " ", page)
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", page))).strip()


def csrf_token(page):
    m = re.search(r'name="csrf-token" content="([^"]+)"', page)
    return m.group(1) if m else ""


class Smoke:
    def __init__(self, args):
        self.a = args
        self.passed = 0
        self.failed = []

    # --- reporting ---

    def check(self, name, ok, detail=""):
        if ok:
            self.passed += 1
            print("  ok    %s" % name)
        else:
            self.failed.append(name)
            print("  FAIL  %s%s" % (name, ("  -- " + detail) if detail else ""))
        return ok

    def section(self, title):
        print("\n" + title)

    # --- portal helpers ---

    def url(self, path):
        return self.a.portal.rstrip("/") + path

    def cas_sign_in(self, netid):
        """Portal /login -> CAS form POST -> /cas/callback?ticket -> home. Returns (browser, callback_url)."""
        b = Browser()
        status, headers, _ = b.get(self.url("/login"))
        cas_login = headers.get("Location", "")
        if status != 302 or "/cas/login" not in cas_login:
            return None, "portal /login did not redirect to CAS (HTTP %s %s)" % (status, cas_login)
        service = urllib.parse.parse_qs(urllib.parse.urlparse(cas_login).query).get("service", [""])[0]
        form_url = cas_login.split("?", 1)[0]
        status, headers, _ = b.post(form_url, {"service": service, "username": netid, "password": PASSWORD})
        callback = headers.get("Location", "")
        if status != 302 or "ticket=ST-" not in callback:
            return None, "CAS did not issue a service ticket (HTTP %s)" % status
        status, headers, _ = b.get(callback)
        if status != 302:
            return None, "callback returned HTTP %s" % status
        return b, callback

    def page(self, b, path):
        status, headers, body = b.get(self.url(path))
        return status, headers, body, text_of(body)

    def submit(self, b, form_page_path, action, extra=None):
        _, _, body = b.get(self.url(form_page_path))
        data = {"authenticity_token": csrf_token(body)}
        data.update(extra or {})
        return b.post(self.url(action), data)

    # --- checks ---

    def run_platform(self):
        self.section("Platform")
        status, _, _ = Browser().get(self.url("/healthz"))
        self.check("portal /healthz is 200", status == 200, "HTTP %s" % status)
        status, headers, _ = Browser().get(self.url("/fines"))
        loc = headers.get("Location", "")
        self.check("signed-out deep link /fines redirects to sign-in, keeping the path",
                   status == 302 and "/login" in loc and "return_to=%2Ffines" in loc, "HTTP %s %s" % (status, loc))

    def run_cas_portal(self):
        self.section("Portal with CAS sign-in (phase %s)" % self.a.phase)
        b, callback = self.cas_sign_in("jstudent")
        if not self.check("jstudent signs in through CAS (redirect, ticket, callback)", b is not None, callback or ""):
            return
        expect_via = "legacy"
        _, _, _, home = self.page(b, "/")
        self.check("home shows NetID and identity provider CAS", "jstudent" in home and "Identity provider CAS" in home)
        self.check("API saw the call as '%s'" % expect_via, "API saw this call as %s" % expect_via in home, home[-300:])
        self.check("footer shows the CAS sign-in", "Sign-in: CAS" in home or "Phase %s" % self.a.phase in home)

        replay = Browser()
        status, _, body = replay.get(callback)
        self.check("replayed CAS ticket is rejected", status == 401 and "INVALID_TICKET" in body, "HTTP %s" % status)

        _, _, _, loans = self.page(b, "/loans")
        self.check("loans come from the API", "Designing Data-Intensive Applications" in loans)
        status, headers, _ = self.submit(b, "/loans", "/loans/reminders")
        _, _, _, after = self.page(b, "/loans")
        self.check("calendar reminders are refused without an Entra token",
                   status == 302 and "need the patron's own Entra token" in after, "HTTP %s" % status)
        _, _, _, fines = self.page(b, "/fines")
        self.check("fines page shows a balance", "Outstanding balance" in fines)
        status, _, _, staff = self.page(b, "/staff?netid=jstudent")
        self.check("student is refused the staff lookup by the API", status == 403 and "Requires the Librarian role" in staff,
                   "HTTP %s" % status)

        alum, err = self.cas_sign_in("aalumni")
        if self.check("aalumni signs in", alum is not None, err or ""):
            status, _, _, eres = self.page(alum, "/eresources")
            self.check("alumni are refused licensed e-resources", status == 403 and "limited to current students" in eres,
                       "HTTP %s" % status)

        fac, err = self.cas_sign_in("mfaculty")
        if self.check("mfaculty signs in", fac is not None, err or ""):
            _, _, _, home = self.page(fac, "/")
            self.check("faculty role comes from the API", "Roles (from the Patron API) Faculty" in home)

        lib, err = self.cas_sign_in("llibrarian")
        if self.check("llibrarian signs in", lib is not None, err or ""):
            status, _, body, staff = self.page(lib, "/staff?netid=jstudent")
            self.check("librarian can look up a patron", status == 200 and "Jordan Student" in staff, "HTTP %s" % status)
            if self.a.mutate:
                m = re.search(r'action="(/staff/patrons/jstudent/fines/([^/"]+)/waive)"', body)
                if m:
                    status, _, _ = self.submit(lib, "/staff?netid=jstudent", m.group(1))
                    _, _, _, staff = self.page(lib, "/staff?netid=jstudent")
                    self.check("librarian waives fine %s" % m.group(2), status == 302 and "Waived %s" % m.group(2) in staff,
                               "HTTP %s" % status)
                else:
                    print("  skip  librarian fine waiver (jstudent has no open fines; restart patron-api to reset)")

        _, _, body = b.get(self.url("/"))
        status, headers, _ = b.post(self.url("/logout"), {"_method": "delete", "authenticity_token": csrf_token(body)})
        self.check("sign-out redirects to CAS logout", status == 302 and "/cas/logout" in headers.get("Location", ""),
                   "HTTP %s" % status)
        status, headers, _ = b.get(self.url("/loans"))
        self.check("after sign-out, /loans requires sign-in", status == 302 and "/login" in headers.get("Location", ""),
                   "HTTP %s" % status)

    def run_entra_portal(self):
        self.section("Portal with Entra sign-in (phase %s)" % self.a.phase)
        b = Browser()
        status, _, body = b.get(self.url("/login"))
        self.check("sign-in page offers Microsoft sign-in", status == 200 and "Sign in with Microsoft" in body, "HTTP %s" % status)
        status, headers, _ = b.post(self.url("/auth/entra_id"), {"authenticity_token": csrf_token(body)})
        loc = headers.get("Location", "")
        self.check("Microsoft sign-in starts an authorization-code request to Entra",
                   status == 302 and "login.microsoftonline.com" in loc and "response_type=code" in loc, "HTTP %s" % status)
        print("  note  signing in to Entra is interactive; complete the user checks by hand (docs/01 section 5)")

    def run_api(self):
        a = self.a
        self.section("Patron API, called directly (phase %s)" % a.phase)
        api = a.api.rstrip("/") + "/api/v1"
        key_ok = a.phase in (0, 1, 2)

        def call(method, path, key=None, user=None):
            headers = {}
            if key is not None:
                headers["X-Api-Key"] = key
            if user:
                headers["X-Remote-User"] = user
            status, _, body = Browser().request(method, api + path, headers=headers)
            try:
                return status, json.loads(body)
            except ValueError:
                return status, {}

        if not a.api_key:
            print("  skip  API checks (no LEGACY_API_KEY in the environment or .env)")
            return
        status, body = call("GET", "/me", a.api_key, "jstudent")
        if key_ok:
            self.check("API key + user header -> 200, labelled legacy",
                       status == 200 and body.get("authenticated_via") == "legacy", "HTTP %s %s" % (status, body))
        else:
            self.check("API key -> 401 (key retired)", status == 401, "HTTP %s" % status)
        status, _ = call("GET", "/me", "wrong-key", "jstudent")
        self.check("wrong API key -> 401", status == 401, "HTTP %s" % status)
        status, _ = call("GET", "/me")
        self.check("no credential -> 401", status == 401, "HTTP %s" % status)
        if key_ok:
            status, _ = call("GET", "/me", a.api_key)
            self.check("API key without a user on /me -> 403", status == 403, "HTTP %s" % status)
            status, _ = call("POST", "/me/loans/reminders", a.api_key, "jstudent")
            self.check("calendar reminders with an API key -> 501", status == 501, "HTTP %s" % status)
            status, _ = call("GET", "/me/graph-profile", a.api_key, "jstudent")
            self.check("Graph OBO check with an API key -> 501", status == 501, "HTTP %s" % status)
            status, _ = call("GET", "/me/token", a.api_key, "jstudent")
            self.check("token view with an API key -> 501 (there is no token)", status == 501, "HTTP %s" % status)
            status, body = call("GET", "/notices/overdue", a.api_key)
            self.check("notices with the API key (job, no user) -> 200", status == 200, "HTTP %s" % status)
            status, _ = call("GET", "/patrons/jstudent", a.api_key, "jstudent")
            self.check("student on the staff endpoint -> 403", status == 403, "HTTP %s" % status)
            status, _ = call("GET", "/me/eresources", a.api_key, "aalumni")
            self.check("alumni on e-resources -> 403", status == 403, "HTTP %s" % status)

    def run(self):
        print("Smoke test: phase %s, portal %s, API %s" % (self.a.phase, self.a.portal, self.a.api or "not called"))
        self.run_platform()
        if self.a.phase in (0, 1):
            self.run_cas_portal()
        else:
            self.run_entra_portal()
        if self.a.api:
            self.run_api()
        print("\n%d passed, %d failed" % (self.passed, len(self.failed)))
        for name in self.failed:
            print("  failed: %s" % name)
        return 0 if not self.failed else 1


def dotenv(name):
    path = os.path.join(ROOT, ".env")
    if not os.path.exists(path):
        return None
    with open(path) as fh:
        for line in fh:
            m = re.match(r"\s*%s\s*=\s*(.*?)\s*(#.*)?$" % re.escape(name), line)
            if m:
                return m.group(1).strip("'\"")
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description="End-to-end smoke test for the Library POC.")
    ap.add_argument("--phase", type=int, choices=[0, 1, 2, 3], required=True, help="migration phase being tested")
    ap.add_argument("--portal", default="http://localhost:3000", help="portal base URL")
    ap.add_argument("--api", default="http://localhost:3001", help="Patron API base URL (internal-only in Azure)")
    ap.add_argument("--no-api", action="store_true", help="skip direct API checks (e.g. against Azure)")
    ap.add_argument("--api-key", default=os.environ.get("LEGACY_API_KEY") or dotenv("LEGACY_API_KEY"))
    ap.add_argument("--mutate", action="store_true", help="also run checks that change data (fine waiver)")
    args = ap.parse_args(argv)
    if args.no_api:
        args.api = None
    return Smoke(args).run()


if __name__ == "__main__":
    sys.exit(main())
