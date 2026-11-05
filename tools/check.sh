#!/usr/bin/env bash
# Runs every check after a change: unit tests (in the built images, so no local Ruby is
# needed), the discovery scanner's tests, then the end-to-end smoke test against the
# running local stack.
#
#   ./tools/check.sh            # phase from PORTAL_AUTH_MODE / PATRON_API_AUTH_MODE in .env
#   ./tools/check.sh 1          # say which phase the local stack is running
#   SKIP_BUILD=1 ./tools/check.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ -f .env ]; then set -a; . ./.env; set +a; fi

if [ -n "${1:-}" ]; then
  PHASE="$1"
else
  case "${PORTAL_AUTH_MODE:-cas}/${PATRON_API_AUTH_MODE:-legacy}" in
    cas/legacy) PHASE=0 ;; cas/both) PHASE=1 ;; entra/both) PHASE=2 ;; entra/entra) PHASE=3 ;;
    *) echo "Can't infer the phase from .env; pass it: $0 <0|1|2|3>" >&2; exit 2 ;;
  esac
fi

FAILED=()
step() { printf '\n==> %s\n' "$1"; shift; "$@" || FAILED+=("$1"); }
# The working tree is mounted at /src, and its gems/ over the image's /gems, so tests run
# against the code on disk rather than the copy baked into the image.
in_image() { docker run --rm -v "$ROOT":/src -v "$ROOT/gems":/gems -w /src "library-entra-poc-$1" bash -c "$2"; }

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  step "Build and restart the local stack" docker compose up -d --build --wait
fi

step "Unit tests: entra_auth gem (with jwt validator tests)" in_image patron-api \
  'cd /app && bundle exec ruby -I/gems/entra_auth/test -e "Dir[\"/gems/entra_auth/test/*_test.rb\"].each { |f| require f }"'
step "Unit tests: patron-api" in_image patron-api \
  'cd /src/patron-api && ruby -Itest/unit -e "Dir[\"test/unit/*_test.rb\"].each { |f| require File.expand_path(f) }"'
step "Unit tests: portal" in_image portal 'ruby portal/test/unit/portal_auth_test.rb'
step "Unit tests: mock CAS" in_image mock-cas 'ruby mock-cas/test/mock_cas_test.rb'
step "Discovery scanner tests" python3 -I tools/discovery/test_scan.py
step "Smoke test (phase $PHASE)" python3 -I tools/smoke/smoke_test.py --phase "$PHASE"

echo
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "All checks passed (phase $PHASE)."
else
  printf 'FAILED: %s\n' "${FAILED[@]}"
  exit 1
fi
