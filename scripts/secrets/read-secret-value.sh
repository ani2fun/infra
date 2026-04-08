#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <namespace> <secret-name> <key>" >&2
  exit 1
fi

namespace="$1"
secret_name="$2"
key="$3"

kubectl get secret "$secret_name" -n "$namespace" -o "jsonpath={.data.${key}}" | base64 -d
echo
