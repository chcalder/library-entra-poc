#!/usr/bin/env bash
# Deletes the POC app registrations (and, with DELETE_TEST_USERS=true, the test users).
set -euo pipefail
PREFIX="${PREFIX:-library-poc}"

for name in portal patron-api notices-job; do
  for id in $(az ad app list --display-name "$PREFIX-$name" --query '[].appId' -o tsv); do
    echo "Deleting app registration $PREFIX-$name ($id)"
    az ad app delete --id "$id"
  done
done

if [ "${DELETE_TEST_USERS:-false}" = "true" ]; then
  DOMAIN="$(az rest --method GET --uri https://graph.microsoft.com/v1.0/domains --query "value[?isDefault].id | [0]" -o tsv)"
  for netid in jstudent mfaculty llibrarian aalumni; do
    az ad user delete --id "$netid@$DOMAIN" 2>/dev/null && echo "Deleted $netid@$DOMAIN" || true
  done
fi

echo "Deleted app registrations stay in the directory's recycle bin for 30 days."
