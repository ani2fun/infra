#!/usr/bin/env bash
# Seal Tangent's runtime Secret and provision its database role, in one go.
#
#   typing-trainer   key postgres-password — the `typing` role's password, URL-safe
#                    because the Deployment interpolates it into a postgres:// URL
#                    key session-secret    — HMAC key for the HttpOnly session cookie
#
# Both values are generated fresh and never printed. The sealed file goes to
# deploy/apps/typing-trainer/overlays/prod/sealedsecret.yaml; then the `typing` role and
# database on the shared Postgres (databases-prod/postgresql-0) are created, or the
# role's password is reset to the new value. Tangent creates its one table itself.
#
# Re-running rotates both: commit and push the new sealed file right away, because
# the running pod keeps the old database password until Argo applies the new Secret
# and the pod restarts (the trainer keeps working meanwhile; only sync pauses), and
# a new session secret signs everybody out.
#
# Set SKIP_DB=1 to only seal (then run the SQL in deploy/apps/typing-trainer/bootstrap.sql
# by hand with the same password — which this script does not show you, so prefer not to).
#
# Needs cluster access (WireGuard up, or run from ms-1).
set -euo pipefail

script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
output="$repo_root/deploy/apps/typing-trainer/overlays/prod/sealedsecret.yaml"

gen() { head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c "$1"; }
db_password="$(gen 32)"
session_secret="$(gen 48)"

"$script_dir/rotate-generic-secret.sh" \
  apps-prod \
  typing-trainer \
  "$output" \
  "postgres-password=$db_password" \
  "session-secret=$session_secret"

if [ "${SKIP_DB:-}" = "1" ]; then
  echo "SKIP_DB=1: database role not touched"
  exit 0
fi

# the password travels on stdin, never on a command line
printf '%s\n' \
  "\\set pw '$db_password'" \
  "SELECT 'CREATE ROLE typing LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'typing') \\gexec" \
  "ALTER ROLE typing WITH LOGIN PASSWORD :'pw';" \
  "SELECT 'CREATE DATABASE typing OWNER typing' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'typing') \\gexec" |
  kubectl -n databases-prod exec -i postgresql-0 -- sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres'

echo "Role and database 'typing' are ready on databases-prod/postgresql-0"
