#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <namespace> <secret-name> <output-yaml> <key=value> [key=value ...]" >&2
  echo "Example: $0 apps-prod dsa-tracker-db deploy/apps/dsa-tracker/overlays/prod/sealedsecret.yaml postgres-password=abc" >&2
}

if [ "$#" -lt 4 ]; then
  usage
  exit 1
fi

namespace="$1"
secret_name="$2"
output_yaml="$3"
shift 3

script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cert_path="${SEALED_SECRETS_CERT:-/tmp/sealed-secrets-cert.pem}"

if [ ! -f "$cert_path" ]; then
  "$script_dir/fetch-sealed-secrets-cert.sh" "$cert_path"
fi

from_literal_args=()
for pair in "$@"; do
  case "$pair" in
    *=*) from_literal_args+=("--from-literal=$pair") ;;
    *)
      echo "Invalid key=value pair: $pair" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$(dirname "$output_yaml")"

kubectl create secret generic "$secret_name" \
  --namespace "$namespace" \
  "${from_literal_args[@]}" \
  --dry-run=client \
  -o yaml | \
  kubeseal \
    --cert "$cert_path" \
    --format yaml \
    > "$output_yaml"

relative_output="$output_yaml"
case "$output_yaml" in
  "$repo_root"/*) relative_output="${output_yaml#$repo_root/}" ;;
esac

echo "Wrote sealed secret to $relative_output"
