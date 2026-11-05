#!/usr/bin/env bash
# Removes the Azure resources (not the Entra app registrations: see infra/entra/teardown.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi
RG="${RG:-rg-library-entra-poc}"

KV="$(az keyvault list -g "$RG" --query '[0].name' -o tsv 2>/dev/null || true)"
az group delete -n "$RG" --yes
# Key Vault is soft-deleted; purge it so the name can be reused.
[ -n "$KV" ] && az keyvault purge -n "$KV" 2>/dev/null || true
rm -f "$ROOT/infra/azure/.last-image-tag"
echo "Deleted $RG"
