#!/usr/bin/env bash
set -euo pipefail

script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"

printf 'username='
"$script_dir/read-secret-value.sh" identity keycloak-admin-secret username
printf 'password='
"$script_dir/read-secret-value.sh" identity keycloak-admin-secret password
