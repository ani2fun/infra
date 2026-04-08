#!/usr/bin/env bash
set -euo pipefail

script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
"$script_dir/read-secret-value.sh" apps-prod dsa-tracker-db postgres-password
