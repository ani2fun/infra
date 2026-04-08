#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <namespace> <secret-name> <output-yaml> <registry-server> <username> <password> [email]" >&2
  echo "Example: $0 apps-prod my-regcred deploy/my-app/overlays/prod/registry-sealedsecret.yaml https://index.docker.io/v1/ docker-user docker-token" >&2
}

if [ "$#" -lt 6 ] || [ "$#" -gt 7 ]; then
  usage
  exit 1
fi

namespace="$1"
secret_name="$2"
output_yaml="$3"
registry_server="$4"
registry_username="$5"
registry_password="$6"
registry_email="${7:-}"

script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cert_path="${SEALED_SECRETS_CERT:-/tmp/sealed-secrets-cert.pem}"

if [ ! -f "$cert_path" ]; then
  "$script_dir/fetch-sealed-secrets-cert.sh" "$cert_path"
fi

mkdir -p "$(dirname "$output_yaml")"

docker_registry_args=(
  kubectl create secret docker-registry "$secret_name"
  --namespace "$namespace"
  --docker-server "$registry_server"
  --docker-username "$registry_username"
  --docker-password "$registry_password"
  --dry-run=client
  -o yaml
)

if [ -n "$registry_email" ]; then
  docker_registry_args+=(--docker-email "$registry_email")
fi

"${docker_registry_args[@]}" | \
  kubeseal \
    --cert "$cert_path" \
    --format yaml \
    > "$output_yaml"

relative_output="$output_yaml"
case "$output_yaml" in
  "$repo_root"/*) relative_output="${output_yaml#$repo_root/}" ;;
esac

echo "Wrote sealed docker-registry secret to $relative_output"
