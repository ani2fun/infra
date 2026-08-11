#!/usr/bin/env bash
# Create-or-update the GitHub identity provider on the `bytebase` Keycloak realm.
#
# GitHub OAuth apps carry ONE authorization callback URL, so the bytebase realm needs its
# OWN OAuth app (the synapse and apps-prod apps cannot be reused):
#   GitHub → Settings → Developer settings → OAuth Apps → New OAuth App
#     Homepage URL:                https://bytebase.kakde.eu
#     Authorization callback URL:  https://keycloak.kakde.eu/realms/bytebase/broker/github/endpoint
#
# First run: pass the new app's client id + secret — they are stored as the
# `bytebase-keycloak-github-oauth` secret in the identity namespace, then the IdP is synced
# from it. Later runs (rotation / re-sync) need no args — the stored secret is reused.
#
#   scripts/secrets/sync-bytebase-github-idp.sh [<client-id> <client-secret>]
#
# Keycloak's GitHub provider imports the GitHub LOGIN as the Keycloak username (syncMode
# IMPORT), so you arrive in the realm as `ani2fun`.
#
# IMPORTANT: this IdP does NOT restrict WHO may sign in — any GitHub account can authorize an
# OAuth app, and first-broker-login will create a realm user for them. Access is gated by
# membership of the `bytebase-admins` group, enforced by oauth2-proxy's --allowed-groups.
# See scripts/secrets/grant-bytebase-admin.sh.
set -euo pipefail

realm="bytebase"
namespace="${KEYCLOAK_NAMESPACE:-identity}"
keycloak_target="${KEYCLOAK_TARGET:-deploy/keycloak}"
server_url="${KEYCLOAK_SERVER_URL:-http://127.0.0.1:8080}"
secret_name="bytebase-keycloak-github-oauth"

for cmd in kubectl jq base64; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

if [ "$#" -ge 2 ]; then
  kubectl -n "$namespace" create secret generic "$secret_name" \
    --from-literal=client-id="$1" \
    --from-literal=client-secret="$2" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Stored $secret_name in namespace $namespace"
fi

if ! kubectl -n "$namespace" get secret "$secret_name" >/dev/null 2>&1; then
  echo "Secret $secret_name not found in namespace $namespace." >&2
  echo "First run needs the GitHub OAuth app credentials:" >&2
  echo "  $0 <client-id> <client-secret>" >&2
  exit 1
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

idp_json_b64="$(printf '%s' "$idp_json" | base64 | tr -d '\n')"
admin_user_b64="$(printf '%s' "$admin_user" | base64 | tr -d '\n')"
admin_password_b64="$(printf '%s' "$admin_password" | base64 | tr -d '\n')"
server_url_b64="$(printf '%s' "$server_url" | base64 | tr -d '\n')"
realm_b64="$(printf '%s' "$realm" | base64 | tr -d '\n')"

kubectl -n "$namespace" exec "$keycloak_target" -- /bin/sh -lc '
  set -euo pipefail
  printf %s "'"$idp_json_b64"'" | base64 -d >/tmp/bytebase-github-idp.json
  admin_user=$(printf %s "'"$admin_user_b64"'" | base64 -d)
  admin_password=$(printf %s "'"$admin_password_b64"'" | base64 -d)
  server_url=$(printf %s "'"$server_url_b64"'" | base64 -d)
  realm=$(printf %s "'"$realm_b64"'" | base64 -d)
  /opt/keycloak/bin/kcadm.sh config credentials --server "$server_url" --realm master --user "$admin_user" --password "$admin_password" >/dev/null
  if /opt/keycloak/bin/kcadm.sh get identity-provider/instances/github -r "$realm" >/dev/null 2>&1; then
    /opt/keycloak/bin/kcadm.sh update identity-provider/instances/github -r "$realm" -f /tmp/bytebase-github-idp.json
    echo "updated existing github IdP on realm $realm"
  else
    /opt/keycloak/bin/kcadm.sh create identity-provider/instances -r "$realm" -f /tmp/bytebase-github-idp.json
    echo "created github IdP on realm $realm"
  fi
  rm -f /tmp/bytebase-github-idp.json
'

echo "Synced the github identity provider on realm $realm"
