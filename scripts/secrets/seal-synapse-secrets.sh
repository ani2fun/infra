#!/usr/bin/env bash
# Seal the two runtime Secrets for synapse (deploy/apps/synapse/base/deployment.yaml):
#
#   synapse-db              key postgres-password — the role created by
#                           deploy/apps/synapse/bootstrap.sql (generated fresh here if not
#                           provided; paste the SAME value into the bootstrap SQL).
#                           Keep it URL-SAFE: since the Rust cutover the Deployment
#                           interpolates it into a postgres:// URL via $(DB_PASSWORD), so a
#                           '@' or '/' would corrupt the connection string. The generator
#                           below already strips /+=.
#
#   synapse-keycloak-admin  key client-secret — the credential of the LEAST-PRIVILEGE
#                           `synapse-admin` service-account client in the `synapse` realm
#                           (client_credentials, scoped to realm-management:manage-users).
#                           Read it from Keycloak with:
#                             kcadm.sh get clients -r synapse -q clientId=synapse-admin --fields id
#                             kcadm.sh get clients/<id>/client-secret -r synapse
#
# CORRECTED 2026-07-18: this used to seal `username`/`password` — a copy of the Keycloak
# BOOTSTRAP ADMIN, which is what the app read before step 37 replaced it with the scoped
# service-account client. The keys had drifted from the Deployment, so running this as the
# runbook instructs would produce a Secret with the wrong keys and leave the pod in
# CreateContainerConfigError. It also sealed a far more powerful credential than the app needs.
#
# Needs cluster access for the Sealed Secrets cert (WireGuard up, or run from ms-1).
#
# Usage:
#   scripts/secrets/seal-synapse-secrets.sh <synapse-admin-client-secret> [db-password]
set -euo pipefail

KC_CLIENT_SECRET="${1:-}"
DB_PASSWORD="${2:-}"

if [ -z "$KC_CLIENT_SECRET" ]; then
  echo "Usage: $0 <synapse-admin-client-secret> [db-password]" >&2
  echo "  This is the 'synapse-admin' CLIENT secret in the 'synapse' realm — NOT the" >&2
  echo "  Keycloak bootstrap admin password, which the app no longer uses." >&2
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
  "client-secret=$KC_CLIENT_SECRET"
