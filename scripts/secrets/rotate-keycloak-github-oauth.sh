#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <github-client-id> <github-client-secret>" >&2
  exit 1
fi

script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

"$script_dir/rotate-generic-secret.sh" \
  identity \
  keycloak-github-oauth \
  "$repo_root/k8s-cluster/apps/keycloak/overlays/prod/github-oauth-sealedsecret.yaml" \
  "client-id=$1" \
  "client-secret=$2"

if kubectl get namespace identity >/dev/null 2>&1; then
  kubectl apply -f "$repo_root/k8s-cluster/apps/keycloak/overlays/prod/github-oauth-sealedsecret.yaml" >/dev/null
  "$script_dir/sync-keycloak-github-idp.sh"
  echo "Applied sealed secret and synced live Keycloak broker"
else
  echo "Cluster access not available; sealed secret file updated only"
fi
