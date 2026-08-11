#!/usr/bin/env bash
# Grant (or revoke) Bytebase access by managing membership of the `bytebase-admins` group
# on the `bytebase` Keycloak realm.
#
#   scripts/secrets/grant-bytebase-admin.sh                    # grant ani2fun (the default)
#   scripts/secrets/grant-bytebase-admin.sh <github-handle>    # grant someone else
#   scripts/secrets/grant-bytebase-admin.sh --revoke <user>    # take access away
#   scripts/secrets/grant-bytebase-admin.sh --list             # who has access, and who is linked
#   scripts/secrets/grant-bytebase-admin.sh --github-id 123 me # skip the GitHub API lookup
#
# THIS GROUP IS THE ACCESS CONTROL. oauth2-proxy runs with --allowed-group=bytebase-admins,
# so membership here is exactly the set of people who can reach https://bytebase.kakde.eu.
# Neither the GitHub OAuth app nor the Keycloak realm restricts who may AUTHENTICATE — any
# GitHub account can broker in and get a realm user created by first-broker-login. They just
# land outside this group and oauth2-proxy turns them away.
#
# ---------------------------------------------------------------------------------------
# WHY THIS SCRIPT LINKS THE GITHUB IDENTITY, AND WHY THAT MATTERS
# ---------------------------------------------------------------------------------------
# Granting access to someone who has never signed in means creating a Keycloak user for them
# up front. That placeholder has no password and no linked identity — so when they later sign
# in through GitHub, Keycloak sees an existing account with the same username and stops at
# "Account already exists ... How do you want to continue?".
#
# Both ways out of that screen are dead ends here:
#   - "Add to existing account" wants to verify ownership by EMAIL, which needs SMTP. The realm
#     has none configured (smtpServer is {}).
#   - The re-authentication alternative wants the existing account's PASSWORD, which a
#     placeholder does not have.
#
# Hit on 2026-08-10 by the repo owner on the very first login. So this script now resolves the
# GitHub numeric user id and links the federated identity AT CREATION TIME, which removes the
# collision before it can happen. `--list` shows who is linked so an unlinked placeholder is
# visible before someone walks into it.
#
# syncMode on the IdP is IMPORT, so the Keycloak username equals the GitHub handle — pass the
# GitHub handle as the username and the lookup works automatically.
set -euo pipefail

realm="bytebase"
group="bytebase-admins"
namespace="${KEYCLOAK_NAMESPACE:-identity}"
keycloak_target="${KEYCLOAK_TARGET:-deploy/keycloak}"
server_url="${KEYCLOAK_SERVER_URL:-http://127.0.0.1:8080}"

action="grant"
username=""
github_id=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --revoke)    action="revoke"; shift ;;
    --list)      action="list";   shift ;;
    --github-id) github_id="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "Unknown flag: $1" >&2; exit 1 ;;
    *)  username="$1"; shift ;;
  esac
done

[ "$action" = "list" ] || username="${username:-ani2fun}"

for cmd in kubectl base64; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

# Resolve the GitHub numeric user id locally (the Keycloak container has no curl). Only needed
# when creating a brand-new user; a best-effort failure is not fatal, it just downgrades to a
# placeholder plus a loud warning.
if [ "$action" = "grant" ] && [ -z "$github_id" ] && command -v curl >/dev/null 2>&1; then
  gh_json="$(curl -sf --max-time 10 "https://api.github.com/users/${username}" 2>/dev/null || true)"
  if [ -n "$gh_json" ]; then
    if command -v python3 >/dev/null 2>&1; then
      github_id="$(printf '%s' "$gh_json" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
    else
      github_id="$(printf '%s' "$gh_json" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)"
    fi
  fi
fi

admin_user="$(kubectl -n "$namespace" get secret keycloak-admin-secret -o jsonpath='{.data.username}' | base64 -d)"
admin_password="$(kubectl -n "$namespace" get secret keycloak-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

# Everything below runs inside the Keycloak pod. kcadm's `--format csv --noquotes` output is
# used instead of JSON so no jq is needed in the container (the Keycloak image has none).
# Values are passed in base64 to keep them out of the process list and dodge quoting issues.
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

kubectl -n "$namespace" exec -i "$keycloak_target" -- /bin/sh -s -- \
  "$(b64 "$admin_user")" "$(b64 "$admin_password")" "$(b64 "$server_url")" \
  "$(b64 "$realm")" "$(b64 "$group")" "$(b64 "$username")" "$action" "$(b64 "$github_id")" <<'REMOTE'
set -eu

admin_user=$(printf %s "$1" | base64 -d)
admin_password=$(printf %s "$2" | base64 -d)
server_url=$(printf %s "$3" | base64 -d)
realm=$(printf %s "$4" | base64 -d)
group=$(printf %s "$5" | base64 -d)
username=$(printf %s "$6" | base64 -d)
action="$7"
github_id=$(printf %s "${8:-}" | base64 -d 2>/dev/null || true)

kcadm=/opt/keycloak/bin/kcadm.sh
# Silence kcadm's "Logging into ..." banner so --list output is readable, but surface the
# real error if authentication actually fails.
if ! "$kcadm" config credentials --server "$server_url" --realm master \
     --user "$admin_user" --password "$admin_password" >/dev/null 2>/tmp/kcadm-auth.err; then
  cat /tmp/kcadm-auth.err >&2
  rm -f /tmp/kcadm-auth.err
  exit 1
fi
rm -f /tmp/kcadm-auth.err

# Is this user's account backed by a real identity, or is it an unlinked placeholder that will
# collide at first login?
link_state() { # $1 = user id -> prints "linked" | "password" | "placeholder"
  if "$kcadm" get "users/$1/federated-identity" -r "$realm" 2>/dev/null | grep -q identityProvider; then
    echo linked
  elif "$kcadm" get "users/$1/credentials" -r "$realm" 2>/dev/null | grep -q '"type"'; then
    echo password
  else
    echo placeholder
  fi
}

# --- resolve the group, creating it if the realm import did not ------------------
group_id=$("$kcadm" get groups -r "$realm" --fields id,name --format csv --noquotes 2>/dev/null \
  | grep ",${group}$" | cut -d, -f1 | head -n1 || true)

if [ -z "$group_id" ]; then
  if [ "$action" = "list" ]; then
    echo "Group '$group' does not exist on realm '$realm'." >&2
    exit 1
  fi
  "$kcadm" create groups -r "$realm" -s "name=${group}" >/dev/null
  group_id=$("$kcadm" get groups -r "$realm" --fields id,name --format csv --noquotes \
    | grep ",${group}$" | cut -d, -f1 | head -n1)
  echo "created group $group"
fi

if [ "$action" = "list" ]; then
  echo "Members of $group (these and only these can reach bytebase.kakde.eu):"
  members=$("$kcadm" get "groups/${group_id}/members" -r "$realm" \
    --fields id,username --format csv --noquotes 2>/dev/null || true)
  if [ -z "$members" ]; then
    echo "  (none)"
  else
    stranded=0
    echo "$members" | while IFS=, read -r mid mname; do
      [ -n "$mname" ] || continue
      case "$(link_state "$mid")" in
        linked)      echo "  $mname  [github linked]" ;;
        password)    echo "  $mname  [local password]" ;;
        placeholder) echo "  $mname  [UNLINKED PLACEHOLDER — will hit 'Account already exists' on first GitHub login]" ;;
      esac
    done
    # `while` runs in a subshell, so re-test outside it for the warning.
    for mid in $(echo "$members" | cut -d, -f1); do
      [ -n "$mid" ] || continue
      [ "$(link_state "$mid")" = placeholder ] && stranded=1
    done
    if [ "$stranded" = 1 ]; then
      echo
      echo "Fix an unlinked placeholder before that person tries to sign in:"
      echo "  scripts/secrets/grant-bytebase-admin.sh <their-github-handle>"
      echo "(re-running is safe and links the identity in place)"
    fi
  fi
  exit 0
fi

# --- resolve the user ------------------------------------------------------------
user_id=$("$kcadm" get users -r "$realm" -q "username=${username}" -q exact=true \
  --fields id,username --format csv --noquotes 2>/dev/null \
  | grep ",${username}$" | cut -d, -f1 | head -n1 || true)

if [ -z "$user_id" ]; then
  if [ "$action" = "revoke" ]; then
    echo "User '$username' does not exist on realm '$realm' — nothing to revoke."
    exit 0
  fi
  "$kcadm" create users -r "$realm" -s "username=${username}" -s enabled=true >/dev/null
  user_id=$("$kcadm" get users -r "$realm" -q "username=${username}" -q exact=true \
    --fields id,username --format csv --noquotes | grep ",${username}$" | cut -d, -f1 | head -n1)
  echo "created user $username"
fi

if [ "$action" = "revoke" ]; then
  "$kcadm" delete "users/${user_id}/groups/${group_id}" -r "$realm" >/dev/null 2>&1 || true
  echo "revoked: $username is no longer in $group"
  exit 0
fi

# --- make sure the account will not collide at first GitHub login ----------------
state=$(link_state "$user_id")
if [ "$state" = placeholder ]; then
  if [ -n "$github_id" ]; then
    "$kcadm" create "users/${user_id}/federated-identity/github" -r "$realm" \
      -s identityProvider=github -s "userId=${github_id}" -s "userName=${username}" >/dev/null 2>&1 \
      && echo "linked GitHub identity ($github_id) — first login will go straight through" \
      || echo "WARNING: could not link the GitHub identity; see the note below" >&2
  else
    echo
    echo "WARNING: '$username' has no linked GitHub identity and no password."
    echo "  Their first GitHub sign-in will stop at \"Account already exists\", and NEITHER"
    echo "  option on that screen can succeed: verify-by-email needs SMTP (this realm has none)"
    echo "  and re-authentication needs a password they do not have."
    echo
    echo "  Fix it by re-running with the GitHub numeric user id:"
    echo "    scripts/secrets/grant-bytebase-admin.sh --github-id <id> $username"
    echo "  Find it with:  curl -s https://api.github.com/users/$username | grep '\"id\"'"
    echo
  fi
fi

"$kcadm" update "users/${user_id}/groups/${group_id}" -r "$realm" \
  -s "realm=${realm}" -s "userId=${user_id}" -s "groupId=${group_id}" -n >/dev/null
echo "granted: $username is in $group"
REMOTE

if [ "$action" != "list" ]; then
  echo
  echo "Verify with: $0 --list"
fi
