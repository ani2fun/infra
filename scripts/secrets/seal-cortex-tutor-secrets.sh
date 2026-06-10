#!/usr/bin/env bash
# Seal the runtime Secret for cortex-tutor and write it to
# deploy/apps/cortex-tutor/overlays/prod/sealedsecret.yaml.
#
# The tutor pod expects two keys (see deploy/apps/cortex-tutor/base/deployment.yaml):
#   anthropic-api-key  — the owner Anthropic key (homelab-allowlist coach/gate tier)
#   mcp-service-token  — bearer the tutor presents to its grounding-MCP sidecar;
#                        generated fresh here if not provided (both containers read
#                        the same Secret key, so rotation is one re-run + commit)
#
# Needs cluster access for the Sealed Secrets cert (WireGuard up, or run from ms-1);
# the cert fetch is handled by rotate-generic-secret.sh / fetch-sealed-secrets-cert.sh.
#
# Usage:
#   scripts/secrets/seal-cortex-tutor-secrets.sh <anthropic-api-key> [mcp-service-token]
#   ANTHROPIC_API_KEY=sk-... scripts/secrets/seal-cortex-tutor-secrets.sh
set -euo pipefail

ANTHROPIC_KEY="${1:-${ANTHROPIC_API_KEY:-}}"
MCP_TOKEN="${2:-}"

if [ -z "$ANTHROPIC_KEY" ]; then
  echo "Usage: $0 <anthropic-api-key> [mcp-service-token]" >&2
  echo "  (or export ANTHROPIC_API_KEY and pass no args)" >&2
  exit 1
fi

if [ -z "$MCP_TOKEN" ]; then
  MCP_TOKEN="$(head -c 32 /dev/urandom | xxd -p -c 64)"
  echo "==> generated fresh mcp-service-token"
fi

script_path="${BASH_SOURCE[0]:-$0}"
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

"$script_dir/rotate-generic-secret.sh" \
  apps-prod \
  cortex-tutor-secrets \
  "$repo_root/deploy/apps/cortex-tutor/overlays/prod/sealedsecret.yaml" \
  "anthropic-api-key=$ANTHROPIC_KEY" \
  "mcp-service-token=$MCP_TOKEN"
