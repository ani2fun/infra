#!/usr/bin/env bash
# Seal the two runtime Secrets for synapse (deploy/apps/synapse/base/deployment.yaml):
#
#   synapse-db              key postgres-password — the role created by
#                           deploy/apps/synapse/bootstrap.sql (generated fresh here
#                           if not provided; paste the SAME value into the bootstrap SQL)
#   synapse-keycloak-admin  keys username/password — a sealed COPY of the Keycloak
#                           bootstrap admin for apps-prod (the canonical secret lives in
#                           the `identity` namespace; pods can't reference it across
#                           namespaces). Read it with
#                           scripts/secrets/read-keycloak-admin-credentials.sh.
#
# Needs cluster access for the Sealed Secrets cert (WireGuard up, or run from ms-1).
#
# Usage:
#   scripts/secrets/seal-synapse-secrets.sh <kc-admin-user> <kc-admin-password> [db-password]
set -euo pipefail

KC_USER="${1:-}"
KC_PASSWORD="${2:-}"
DB_PASSWORD="${3:-}"

if [ -z "$KC_USER" ] || [ -z "$KC_PASSWORD" ]; then
  echo "Usage: $0 <kc-admin-user> <kc-admin-password> [db-password]" >&2
  echo "  (read the admin pair with scripts/secrets/read-keycloak-admin-credentials.sh)" >&2
  exit 1
fi

if [ -z "$DB_PASSWORD" ]; then
  DB_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
  echo "==> generated fresh synapse db password — use it in bootstrap.sql:"
  echo "    $DB_PASSWORD"
fi

script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

"$script_dir/rotate-generic-secret.sh" \
  apps-prod \
  synapse-db \
  "$repo_root/deploy/apps/synapse/overlays/prod/sealedsecret-db.yaml" \
  "postgres-password=$DB_PASSWORD"

"$script_dir/rotate-generic-secret.sh" \
  apps-prod \
  synapse-keycloak-admin \
  "$repo_root/deploy/apps/synapse/overlays/prod/sealedsecret-keycloak-admin.yaml" \
  "username=$KC_USER" \
  "password=$KC_PASSWORD"
