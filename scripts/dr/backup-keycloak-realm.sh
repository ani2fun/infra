#!/usr/bin/env bash
# Capture the `kakde` realm from the live Keycloak via the admin REST API.
# Safer than `kc.sh export` because it does not require stopping the running
# Keycloak process.
#
# Usage:
#   scripts/dr/backup-keycloak-realm.sh /path/to/output/dir
set -euo pipefail

OUT_DIR="${1:?usage: $0 <output-dir>}"
mkdir -p "$OUT_DIR"

KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.kakde.eu}"
REALM="${REALM:-kakde}"
CLIENT_ID="${CLIENT_ID:-admin-cli}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

script_dir="$(cd "$(dirname "$0")" && pwd)"
secrets_dir="${script_dir}/../secrets"

if [[ ! -x "${secrets_dir}/read-keycloak-admin-credentials.sh" ]]; then
  echo "missing helper: ${secrets_dir}/read-keycloak-admin-credentials.sh" >&2
  exit 1
fi

echo "==> reading admin credentials"
creds="$("${secrets_dir}/read-keycloak-admin-credentials.sh")"
ADMIN_USER="$(echo "$creds" | sed -n 's/^username=//p')"
ADMIN_PASS="$(echo "$creds" | sed -n 's/^password=//p')"

if [[ -z "$ADMIN_USER" || -z "$ADMIN_PASS" ]]; then
  echo "could not extract admin credentials" >&2
  exit 1
fi

echo "==> obtaining admin access token"
TOKEN="$(curl -fsS \
  -X POST \
  -d "grant_type=password" \
  -d "client_id=${CLIENT_ID}" \
  -d "username=${ADMIN_USER}" \
  --data-urlencode "password=${ADMIN_PASS}" \
  "https://${KEYCLOAK_HOST}/realms/master/protocol/openid-connect/token" \
  | jq -r '.access_token')"

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "failed to obtain access token" >&2
  exit 1
fi

echo "==> exporting realm '${REALM}' (with clients)"
out_file="${OUT_DIR}/${REALM}-realm-${TS}.json"
curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://${KEYCLOAK_HOST}/admin/realms/${REALM}?exportClients=true" \
  > "${out_file}"

chmod 0600 "${out_file}"

if ! jq -e '.realm == "'"${REALM}"'"' "${out_file}" >/dev/null; then
  echo "exported file does not look like a ${REALM} realm export" >&2
  rm -f "${out_file}"
  exit 1
fi

clients="$(jq '.clients | length' "${out_file}")"
roles="$(jq '.roles.realm | length' "${out_file}")"
sha="$(shasum -a 256 "${out_file}" | awk '{print $1}')"

cat <<EOF

==> export complete
file:    ${out_file}
clients: ${clients}
roles:   ${roles}
sha256:  ${sha}

NOT INCLUDED in the export (regenerate / reset on restore):
  - GitHub OAuth client secret  -- regenerate at github.com
  - user passwords              -- expect to issue resets after import
  - active sessions / tokens

NEXT STEPS:
  1. Move the file to encrypted off-cluster storage.
  2. Record the sha256 above in your password manager.
  3. To import on a fresh Keycloak, follow:
     deploy/dr/keycloak-realm-export.md
EOF
