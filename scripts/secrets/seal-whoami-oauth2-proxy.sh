#!/usr/bin/env bash
# Seal the runtime Secret for whoami-oauth2-proxy and write it to
# deploy/apps/whoami/overlays/prod/sealedsecret-oauth2-proxy.yaml.
#
# Generates a fresh cookie-secret if one is not provided.
#
# Usage:
#   scripts/secrets/seal-whoami-oauth2-proxy.sh <client-id> <client-secret> [cookie-secret]
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <keycloak-client-id> <keycloak-client-secret> [cookie-secret]" >&2
  exit 1
fi

CLIENT_ID="$1"
CLIENT_SECRET="$2"
COOKIE_SECRET="${3:-}"

script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

if [ -z "$COOKIE_SECRET" ]; then
  COOKIE_SECRET="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  echo "==> generated fresh cookie-secret"
fi

"$script_dir/rotate-generic-secret.sh" \
  apps \
  whoami-oauth2-proxy \
  "$repo_root/deploy/apps/whoami/overlays/prod/sealedsecret-oauth2-proxy.yaml" \
  "client-id=$CLIENT_ID" \
  "client-secret=$CLIENT_SECRET" \
  "cookie-secret=$COOKIE_SECRET"

echo "==> sealed secret written to deploy/apps/whoami/overlays/prod/sealedsecret-oauth2-proxy.yaml"
echo
echo "next steps:"
echo "  1. uncomment the oauth2-proxy resources in base/kustomization.yaml"
echo "  2. uncomment sealedsecret-oauth2-proxy.yaml and ingress-whoami-auth.yaml"
echo "     in overlays/prod/kustomization.yaml"
echo "  3. kubectl apply -k deploy/apps/whoami/overlays/prod/"
echo "  4. verify with: curl -sI https://whoami-auth.kakde.eu"
