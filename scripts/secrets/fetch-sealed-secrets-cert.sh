#!/usr/bin/env bash
set -euo pipefail

output_path="${1:-/tmp/sealed-secrets-cert.pem}"

kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d > "$output_path"

echo "Wrote Sealed Secrets certificate to $output_path"
