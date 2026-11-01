#!/usr/bin/env bash
# Seal a GHCR image pull secret for an app whose image is private.
#
#   scripts/secrets/seal-ghcr-pull-secret.sh <namespace> <output-yaml> [secret-name]
#
# Needs a classic GitHub PAT with only the read:packages scope:
#   https://github.com/settings/tokens/new?scopes=read:packages&description=k3s-ghcr-pull
# The token is read from the terminal without echo and never written to disk.
set -euo pipefail

namespace="${1:?usage: $0 <namespace> <output-yaml> [secret-name]}"
output="${2:?usage: $0 <namespace> <output-yaml> [secret-name]}"
name="${3:-ghcr-pull}"
user="${GHCR_USER:-ani2fun}"
cert="${SEALED_SECRETS_CERT:-/tmp/sealed-secrets-cert.pem}"
controller="${CONTROLLER_SSH:-root@192.168.15.2}"

command -v kubeseal >/dev/null || { echo "kubeseal missing: brew install kubeseal" >&2; exit 1; }

if [ ! -s "$cert" ]; then
  ssh "$controller" \
    "kubectl get secret -n kube-system \
    -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
    -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d" > "$cert"
  echo "Wrote Sealed Secrets certificate to $cert"
fi

read -rsp "GHCR token for $user (read:packages): " token
echo
[ -n "$token" ] || { echo "no token given" >&2; exit 1; }

kubectl create secret docker-registry "$name" \
  --namespace "$namespace" \
  --docker-server=ghcr.io \
  --docker-username="$user" \
  --docker-password="$token" \
  --dry-run=client -o yaml |
  kubeseal --cert "$cert" --format yaml > "$output"

echo "Wrote sealed $namespace/$name to $output"
