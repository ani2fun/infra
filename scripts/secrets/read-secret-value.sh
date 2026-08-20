#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <namespace> <secret-name> <key>" >&2
  exit 1
fi

namespace="$1"
secret_name="$2"
key="$3"

jsonpath="jsonpath={.data.${key}}"

# Prefer the caller's own kubectl (works when an API tunnel is up), but fall
# back to running kubectl on ms-1 over SSH. Every other script in the DR pack
# already reaches the cluster that way, and the backup flow must not depend on
# a tunnel being open — that is precisely the situation a recovery runs in.
raw=""
if ! raw="$(kubectl get secret "$secret_name" -n "$namespace" -o "$jsonpath" 2>/dev/null)" || [ -z "$raw" ]; then
  raw="$(ssh -n -o BatchMode=yes -o ConnectTimeout=8 ms-1 \
    "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get secret ${secret_name} -n ${namespace} -o '${jsonpath}'" 2>/dev/null || true)"
fi

if [ -z "$raw" ]; then
  echo "error: could not read ${namespace}/${secret_name} key '${key}' via local kubectl or ms-1" >&2
  exit 1
fi

printf '%s' "$raw" | base64 -d
echo
