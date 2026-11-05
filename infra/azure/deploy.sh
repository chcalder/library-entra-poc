#!/usr/bin/env bash
# Deploys the Library POC to Azure Container Apps at a given migration phase.
#
#   ./infra/azure/deploy.sh 0    CAS + API key ("before"; no Entra setup needed)
#   ./infra/azure/deploy.sh 1    Patron API accepts API key AND Entra tokens (dual-accept)
#   ./infra/azure/deploy.sh 2    Portal signs in with Entra OIDC; Patron API uses OBO to Graph;
#                                notices job uses client credentials
#   ./infra/azure/deploy.sh 3    API key retired: Entra tokens only
#
# Phases 1-3 need infra/entra/setup-app-registrations.sh to have run first.
# Settings come from .env at the repo root (RG, LOCATION, PREFIX, Entra IDs and secrets).
# SKIP_BUILD=1 reuses the images from the previous run (faster phase changes).
set -euo pipefail

PHASE="${1:-0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/infra/azure"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

RG="${RG:-rg-library-entra-poc}"
LOCATION="${LOCATION:-westus3}"
PREFIX="${PREFIX:-libpoc}"
log() { printf '\n==> %s\n' "$*"; }

case "$PHASE" in
  0) PORTAL_MODE=cas;   API_MODE=legacy; JOB_MODE=legacy; LABEL="Phase 0 · CAS + API key" ;;
  1) PORTAL_MODE=cas;   API_MODE=both;   JOB_MODE=legacy; LABEL="Phase 1 · API accepts Entra tokens" ;;
  2) PORTAL_MODE=entra; API_MODE=both;   JOB_MODE=entra;  LABEL="Phase 2 · Entra OIDC + OBO to Graph" ;;
  3) PORTAL_MODE=entra; API_MODE=entra;  JOB_MODE=entra;  LABEL="Phase 3 · API key retired" ;;
  *) echo "Usage: $0 <0|1|2|3>" >&2; exit 1 ;;
esac

if [ "$PHASE" -ge 1 ]; then
  for v in ENTRA_TENANT_ID PORTAL_CLIENT_ID PATRON_API_CLIENT_ID JOB_CLIENT_ID PATRON_API_CLIENT_SECRET; do
    [ -n "${!v:-}" ] || { echo "$v is empty: run infra/entra/setup-app-registrations.sh first." >&2; exit 1; }
  done
fi

# `az containerapp` (used to reuse generated secrets on redeploy) needs this extension.
az extension show --name containerapp -o none 2>/dev/null || az extension add --name containerapp --only-show-errors

log "Phase $PHASE: portal=$PORTAL_MODE, patron-api=$API_MODE, job=$JOB_MODE"
az group create -n "$RG" -l "$LOCATION" -o none

log "1/5 Platform: registry, identity, Container Apps environment"
OUT="$(az deployment group create -g "$RG" -n platform -f "$HERE/main.bicep" \
  -p prefix="$PREFIX" deployApps=false \
  --query properties.outputs -o json)"
out() { echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['$1']['value'])"; }
ACR="$(out acrName)"

log "2/5 Container images"
TAG_FILE="$HERE/.last-image-tag"
if [ "${SKIP_BUILD:-0}" = "1" ] && [ -f "$TAG_FILE" ]; then
  TAG="$(cat "$TAG_FILE")"; echo "   reusing tag $TAG"
else
  TAG="$(date +%Y%m%d%H%M%S)"
  for app in mock-cas patron-api portal; do
    az acr build -r "$ACR" -t "$app:$TAG" -f "$app/Dockerfile" "$ROOT" --no-logs -o none
    echo "   built $app:$TAG"
  done
  echo "$TAG" >"$TAG_FILE"
fi

log "3/5 Secrets"
# Container Apps secrets, passed to Bicep in a parameters file (not on the command line).
# Generated values are reused from the running apps, so redeploys keep sessions and the key.
existing() { # app secret-name
  az containerapp secret show -g "$RG" -n "$PREFIX-$1" --secret-name "$2" --query value -o tsv 2>/dev/null || true
}
rand_hex() { python3 -c "import secrets; print(secrets.token_hex($1))"; }
SKB="$(existing portal portal-secret-key-base)"; [ -n "$SKB" ] || SKB="$(rand_hex 64)"
API_KEY="$(existing patron-api legacy-api-key)"; [ -n "$API_KEY" ] || API_KEY="$(rand_hex 24)"
SECRETS_FILE="$(mktemp)"; chmod 600 "$SECRETS_FILE"; trap 'rm -f "$SECRETS_FILE"' EXIT
SKB="$SKB" API_KEY="$API_KEY" python3 - "$SECRETS_FILE" <<'PY'
import json, os, sys
v = lambda k: {"value": os.environ.get(k, "")}
params = {"secretKeyBase": v("SKB"), "legacyApiKey": v("API_KEY"), "portalClientSecret": v("PORTAL_CLIENT_SECRET"),
          "patronApiClientSecret": v("PATRON_API_CLIENT_SECRET"), "jobClientSecret": v("JOB_CLIENT_SECRET")}
json.dump({"$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
           "contentVersion": "1.0.0.0", "parameters": params}, open(sys.argv[1], "w"))
PY
echo "   portal-secret-key-base, legacy-api-key, client secrets ready"

log "4/5 Apps"
OUT="$(az deployment group create -g "$RG" -n "apps-phase$PHASE" -f "$HERE/main.bicep" \
  -p "@$SECRETS_FILE" \
  -p prefix="$PREFIX" deployApps=true imageTag="$TAG" \
     portalAuthMode="$PORTAL_MODE" patronApiAuthMode="$API_MODE" jobAuthMode="$JOB_MODE" \
     phaseLabel="$LABEL" tenantId="${ENTRA_TENANT_ID:-}" \
     portalClientId="${PORTAL_CLIENT_ID:-}" patronApiClientId="${PATRON_API_CLIENT_ID:-}" \
     jobClientId="${JOB_CLIENT_ID:-}" patronApiScopes="${PATRON_API_SCOPES:-}" \
     finesAuthContext="${FINES_AUTH_CONTEXT:-}" graphTimeZone="${GRAPH_TIME_ZONE:-Pacific Standard Time}" \
  --query properties.outputs -o json)"
PORTAL_URL="$(out portalUrl)"; CAS_URL="$(out casUrl)"; REDIRECT="$(out portalRedirectUri)"; JOB="$(out noticesJobName)"

log "5/5 Portal redirect URI"
if [ -n "${PORTAL_CLIENT_ID:-}" ]; then
  CURRENT="$(az ad app show --id "$PORTAL_CLIENT_ID" --query 'web.redirectUris' -o tsv)"
  if ! grep -qxF "$REDIRECT" <<<"$CURRENT"; then
    # shellcheck disable=SC2086
    az ad app update --id "$PORTAL_CLIENT_ID" --web-redirect-uris $CURRENT "$REDIRECT" --only-show-errors
    echo "   added $REDIRECT"
  else
    echo "   already registered"
  fi
else
  echo "   skipped (no Entra app registrations yet)"
fi

log "Done: $LABEL"
echo "   Portal     $PORTAL_URL"
echo "   Mock CAS   $CAS_URL   (NetIDs jstudent, mfaculty, llibrarian, aalumni; password: password)"
echo "   Run the notices job now:  az containerapp job start -g $RG -n $JOB"
echo "   Logs:  az containerapp logs show -g $RG -n $PREFIX-patron-api --follow"
