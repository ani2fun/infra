#!/usr/bin/env bash
set -euo pipefail

realm="${KEYCLOAK_REALM:-apps-prod}"
namespace="${KEYCLOAK_NAMESPACE:-identity}"
keycloak_target="${KEYCLOAK_TARGET:-deploy/keycloak}"
server_url="${KEYCLOAK_SERVER_URL:-http://127.0.0.1:8080}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd kubectl
require_cmd jq
require_cmd base64

client_id="$(kubectl -n "$namespace" get secret keycloak-github-oauth -o jsonpath='{.data.client-id}' | base64 -d)"
client_secret="$(kubectl -n "$namespace" get secret keycloak-github-oauth -o jsonpath='{.data.client-secret}' | base64 -d)"
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

idp_json_b64="$(printf '%s' "$idp_json" | base64 | tr -d '\n')"
admin_user_b64="$(printf '%s' "$admin_user" | base64 | tr -d '\n')"
admin_password_b64="$(printf '%s' "$admin_password" | base64 | tr -d '\n')"
server_url_b64="$(printf '%s' "$server_url" | base64 | tr -d '\n')"
realm_b64="$(printf '%s' "$realm" | base64 | tr -d '\n')"

kubectl -n "$namespace" exec "$keycloak_target" -- /bin/sh -lc '
  set -euo pipefail
  printf %s "'"$idp_json_b64"'" | base64 -d >/tmp/github-idp.json
  admin_user=$(printf %s "'"$admin_user_b64"'" | base64 -d)
  admin_password=$(printf %s "'"$admin_password_b64"'" | base64 -d)
  server_url=$(printf %s "'"$server_url_b64"'" | base64 -d)
  realm=$(printf %s "'"$realm_b64"'" | base64 -d)
  /opt/keycloak/bin/kcadm.sh config credentials --server "$server_url" --realm master --user "$admin_user" --password "$admin_password" >/dev/null
  /opt/keycloak/bin/kcadm.sh update identity-provider/instances/github -r "$realm" -f /tmp/github-idp.json
  rm -f /tmp/github-idp.json
'

echo "Synced Keycloak github identity provider from Kubernetes secret"
