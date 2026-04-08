#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <dockerhub-username> <dockerhub-token> [dockerhub-email]" >&2
  exit 1
fi

script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

"$script_dir/rotate-docker-registry-secret.sh" \
  apps-prod \
  dsa-tracker-regcred \
  "$repo_root/deploy/dsa-tracker/overlays/prod/registry-sealedsecret.yaml" \
  https://index.docker.io/v1/ \
  "$1" \
  "$2" \
  "${3:-}"

if kubectl get namespace apps-prod >/dev/null 2>&1; then
  kubectl apply -f "$repo_root/deploy/dsa-tracker/overlays/prod/registry-sealedsecret.yaml" >/dev/null
  echo "Applied sealed secret for dsa-tracker-regcred"
else
  echo "Cluster access not available; sealed secret file updated only"
fi
