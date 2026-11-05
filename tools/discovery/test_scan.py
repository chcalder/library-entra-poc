#!/usr/bin/env python3
"""Tests for scan.py against a small synthetic app.  python3 tools/discovery/test_scan.py"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scan  # noqa: E402

FIXTURE = {
    "Gemfile": 'gem "rack-cas"\ngem "net-ldap"\n',
    "config/initializers/cas.rb": (
        'Rails.application.config.rack_cas.server_url = ENV["CAS_SERVER_URL"]\n'
        'CAS_OPTS = { gateway: true, renew: false }\n'
        'PGT_CALLBACK = "https://app.example.edu/cas/proxy_callback" # pgtUrl\n'
    ),
    "app/controllers/application_controller.rb": (
        "class ApplicationController\n"
        "  def current_user = User.find_by(netid: session[:cas_user])\n"
        '  def staff? = session[:cas_extra_attributes]["eduPersonAffiliation"].include?("staff")\n'
        "end\n"
    ),
    "app/services/bursar_client.rb": (
        'API_KEY = "sk_live_abcdef123456"\n'
        "def call = Faraday.get(url, nil, { 'X-Api-Key' => API_KEY, 'X-Remote-User' => netid })\n"
    ),
    "app/jobs/sync_job.rb": "class SyncJob < ApplicationJob; end\n",
    "config/settings.yml": "bursar:\n  api_key: hunter2hunter2\n",
    "apache/app.conf": "AuthType CAS\nCASLoginURL https://cas.example.edu/cas/login\n",
    ".env": "CAS_SECRET=never-read-this\n",
    "spec/cas_spec.rb": "describe 'serviceValidate' do; end\n",
    "README.md": "We use CAS proxyValidate.\n",
}


class ScanTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        for rel, text in FIXTURE.items():
            path = os.path.join(cls.tmp.name, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as fh:
                fh.write(text)
        cls.findings, cls.settings, cls.stats = scan.scan(cls.tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def files(self, cid):
        return {h["file"] for h in self.findings[cid]}

    def test_finds_each_kind_of_dependency(self):
        self.assertIn("Gemfile", self.files("CAS-LIB"))
        self.assertIn("config/initializers/cas.rb", self.files("CAS-PROXY"))
        self.assertIn("config/initializers/cas.rb", self.files("CAS-OPTS"))
        self.assertIn("apache/app.conf", self.files("WEB-AUTH"))
        self.assertIn("Gemfile", self.files("OTHER-IDP"))
        self.assertIn("app/controllers/application_controller.rb", self.files("ATTR"))
        self.assertIn("app/controllers/application_controller.rb", self.files("ID-KEY"))
        self.assertIn("app/controllers/application_controller.rb", self.files("AUTHZ"))
        self.assertIn("app/controllers/application_controller.rb", self.files("SESSION"))
        self.assertIn("app/services/bursar_client.rb", self.files("SHARED-SECRET"))
        self.assertIn("app/services/bursar_client.rb", self.files("HTTP-CLIENT"))
        self.assertIn("app/jobs/sync_job.rb", self.files("JOBS"))
        self.assertIn("CAS_SERVER_URL", self.settings)

    def test_never_reads_env_files_and_skips_tests_and_docs_by_default(self):
        self.assertIn(".env", self.stats["skipped"]["may contain secrets (not read)"])
        all_files = {h["file"] for hits in self.findings.values() for h in hits}
        self.assertNotIn(".env", all_files)
        self.assertNotIn("spec/cas_spec.rb", all_files)
        self.assertNotIn("README.md", all_files)
        self.assertNotIn("CAS_SECRET", self.settings)

    def test_redacts_literal_credentials(self):
        report = scan.render_markdown(self.tmp.name, self.findings, self.settings, self.stats, 40, 5)
        self.assertNotIn("sk_live_abcdef123456", report)
        self.assertNotIn("hunter2hunter2", report)
        self.assertIn("[REDACTED]", report)

    def test_questions_follow_findings(self):
        cats = {cid for cid, _ in scan.questions_for(self.findings)}
        self.assertIn("CAS-PROXY", cats)
        self.assertNotIn("NETWORK-TRUST", cats)

    def test_opt_ins_and_json(self):
        findings, _, _ = scan.scan(self.tmp.name, include_tests=True, include_docs=True)
        files = {h["file"] for hits in findings.values() for h in hits}
        self.assertIn("spec/cas_spec.rb", files)
        self.assertIn("README.md", files)
        data = json.loads(scan.render_json(self.tmp.name, self.findings, self.settings, self.stats))
        self.assertEqual(len(data["categories"]), len(scan.CATEGORIES))

    def test_no_cas_found_hint(self):
        with tempfile.TemporaryDirectory() as empty:
            with open(os.path.join(empty, "app.rb"), "w") as fh:
                fh.write("puts 1\n")
            f, s, st = scan.scan(empty)
            self.assertIn("No CAS integration found", scan.render_markdown(empty, f, s, st, 40, 5))


if __name__ == "__main__":
    unittest.main()
