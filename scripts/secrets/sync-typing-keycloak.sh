#!/usr/bin/env bash
# Create the `typing` Keycloak realm (if missing) and create-or-update its GitHub
# identity provider, for Tangent's sign-in at https://typing.kakde.eu.
#
# GitHub OAuth apps carry ONE authorization callback URL, so the typing realm needs its
# OWN OAuth app:
#   GitHub → Settings → Developer settings → OAuth Apps → New OAuth App
#     Homepage URL:                https://typing.kakde.eu
#     Authorization callback URL:  https://keycloak.kakde.eu/realms/typing/broker/github/endpoint
#
# First run: pass the new app's client id; the client secret is read from the terminal
# without echo. Both are stored as the `typing-keycloak-github-oauth` secret in the
# identity namespace, then the IdP is synced from it. Later runs (rotation / re-sync)
# need no args — the stored secret is reused.
#
#   scripts/secrets/sync-typing-keycloak.sh [<client-id>]
#
# The realm comes from deploy/apps/typing-trainer/keycloak-realm-prod.json and is only
# imported when it does not exist yet; later edits to that file are not re-applied.
#
# Keycloak's GitHub provider imports the GitHub LOGIN as the Keycloak username (syncMode
# IMPORT), so the ID token's preferred_username is the GitHub handle — which is what the
# Deployment's ALLOWED_USERS list matches.
#
# Needs cluster access (WireGuard up, or run from ms-1).
set -euo pipefail

realm="typing"
namespace="${KEYCLOAK_NAMESPACE:-identity}"
keycloak_target="${KEYCLOAK_TARGET:-deploy/keycloak}"
server_url="${KEYCLOAK_SERVER_URL:-http://127.0.0.1:8080}"
secret_name="typing-keycloak-github-oauth"

script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
realm_file="$repo_root/deploy/apps/typing-trainer/keycloak-realm-prod.json"

for cmd in kubectl jq base64; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

if [ "$#" -ge 1 ]; then
  read -rsp "GitHub OAuth app client secret: " client_secret_in
  echo
  [ -n "$client_secret_in" ] || { echo "no client secret given" >&2; exit 1; }
  kubectl -n "$namespace" create secret generic "$secret_name" \
    --from-literal=client-id="$1" \
    --from-literal=client-secret="$client_secret_in" \
    --dry-run=client -o yaml | kubectl apply -f -
  unset client_secret_in
  echo "Stored $secret_name in namespace $namespace"
fi

client_id="$(kubectl -n "$namespace" get secret "$secret_name" -o jsonpath='{.data.client-id}' | base64 -d)"
client_secret="$(kubectl -n "$namespace" get secret "$secret_name" -o jsonpath='{.data.client-secret}' | base64 -d)"
admin_user="$(kubectl -n "$namespace" get secret keycloak-admin-secret -o jsonpath='{.data.username}' | base64 -d)"
admin_password="$(kubectl -n "$namespace" get secret keycloak-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

idp_json="$(jq -cn \
  --arg clientId "$client_id" \
  --arg clientSecret "$client_secret" \
  '{
    alias: "github",
    displayName: "GitHub",
    providerId: "github",
    enabled: true,
    trustEmail: true,
    storeToken: false,
    addReadTokenRoleOnCreate: false,
    authenticateByDefault: false,
    linkOnly: false,
    firstBrokerLoginFlowAlias: "first broker login",
    config: {
      clientId: $clientId,
      clientSecret: $clientSecret,
      defaultScope: "user:email",
      syncMode: "IMPORT"
    }
  }')"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
realm_json_b64="$(jq -c . "$realm_file" | base64 | tr -d '\n')"
idp_json_b64="$(b64 "$idp_json")"
admin_user_b64="$(b64 "$admin_user")"
admin_password_b64="$(b64 "$admin_password")"
server_url_b64="$(b64 "$server_url")"
realm_b64="$(b64 "$realm")"

kubectl -n "$namespace" exec "$keycloak_target" -- /bin/sh -lc '
  set -euo pipefail
  kc=/opt/keycloak/bin/kcadm.sh
  printf %s "'"$realm_json_b64"'" | base64 -d >/tmp/typing-realm.json
  printf %s "'"$idp_json_b64"'" | base64 -d >/tmp/typing-github-idp.json
  trap "rm -f /tmp/typing-realm.json /tmp/typing-github-idp.json" EXIT
  admin_user=$(printf %s "'"$admin_user_b64"'" | base64 -d)
  admin_password=$(printf %s "'"$admin_password_b64"'" | base64 -d)
  server_url=$(printf %s "'"$server_url_b64"'" | base64 -d)
  realm=$(printf %s "'"$realm_b64"'" | base64 -d)
  $kc config credentials --server "$server_url" --realm master --user "$admin_user" --password "$admin_password" >/dev/null
  if $kc get "realms/$realm" >/dev/null 2>&1; then
    echo "realm $realm already exists (not re-imported)"
  else
    $kc create realms -f /tmp/typing-realm.json
    echo "created realm $realm"
  fi
  if $kc get identity-provider/instances/github -r "$realm" >/dev/null 2>&1; then
    $kc update identity-provider/instances/github -r "$realm" -f /tmp/typing-github-idp.json
    echo "updated existing github IdP on realm $realm"
  else
    $kc create identity-provider/instances -r "$realm" -f /tmp/typing-github-idp.json
    echo "created github IdP on realm $realm"
  fi
'

echo "Synced realm $realm and its github identity provider"
