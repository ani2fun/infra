#!/usr/bin/env bash
# Compare the live cluster's headline versions against k8s-cluster/dr/SNAPSHOT.md.
# Reports drift so you can refresh the snapshot before it goes stale in DR.
#
# Read-only. Exits 0 on no drift, 1 on drift.
#
# Usage:
#   scripts/dr/verify-snapshot.sh
set -euo pipefail

SNAPSHOT="$(dirname "$0")/../../k8s-cluster/dr/SNAPSHOT.md"
if [[ ! -f "$SNAPSHOT" ]]; then
  echo "snapshot not found: $SNAPSHOT" >&2
  exit 2
fi

ssh_ms1() { ssh -o BatchMode=yes -o ConnectTimeout=8 ms-1 "$@"; }
kubectl_ms1() { ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $*"; }

# Pull a "Component | Version |" table row out of the snapshot. Returns the
# Version cell.
snap_version() {
  local component="$1"
  awk -v c="$component" -F'|' '
    /^\| Component \| Version /{ in_table=1; next }
    /^\|---/ && in_table { next }
    /^[^|]/ { in_table=0 }
    in_table {
      gsub(/^[ \t]+|[ \t]+$/, "", $2)
      gsub(/^[ \t]+|[ \t]+$/, "", $3)
      if ($2 == c) { print $3; exit }
    }
  ' "$SNAPSHOT"
}

drift=0
check() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf "  OK   %-30s = %s\n" "$label" "$actual"
  else
    printf "  DRIFT %-30s expected=%s actual=%s\n" "$label" "$expected" "$actual"
    drift=1
  fi
}

echo "=> verifying live cluster against $SNAPSHOT"

# K3s version
expected_k3s="$(snap_version "K3s / kubelet")"
[[ -z "$expected_k3s" ]] && expected_k3s="$(snap_version "K3s")"
actual_k3s="$(kubectl_ms1 "get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'" 2>/dev/null || echo unknown)"
check "K3s kubelet" "$expected_k3s" "$actual_k3s"

# cert-manager Helm chart
expected_cm="$(awk -F'|' '/cert-manager.*v1\./ && / Helm chart /==0 {next} / cert-manager / && / [|][^|]*v1\.[0-9]/ {print}' "$SNAPSHOT" | head -1)"
actual_cm="$(ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm -n cert-manager list -o json 2>/dev/null" | jq -r '.[0].chart' 2>/dev/null || echo unknown)"
# soft-grep the snapshot for the expected chart string
if grep -q "$actual_cm" "$SNAPSHOT" 2>/dev/null; then
  printf "  OK   %-30s = %s\n" "cert-manager Helm chart" "$actual_cm"
else
  printf "  DRIFT %-30s actual=%s (not found in snapshot)\n" "cert-manager Helm chart" "$actual_cm"
  drift=1
fi

# Argo CD synced revisions per app
echo
echo "=> Argo CD Application revisions:"
kubectl_ms1 "get application -n argocd -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.revision}{\"\\n\"}{end}'" | while IFS='=' read -r name rev; do
  [[ -z "$name" ]] && continue
  if grep -q "$rev" "$SNAPSHOT"; then
    printf "  OK   %-25s = %s\n" "$name" "$rev"
  else
    printf "  DRIFT %-25s actual=%s (not in snapshot)\n" "$name" "$rev"
    # this script prints DRIFT but doesn't fail on app revisions because
    # those naturally move over time; treat them as informational
  fi
done

echo
if [[ $drift -eq 0 ]]; then
  echo "no drift detected"
  exit 0
else
  echo "DRIFT detected. Consider regenerating the snapshot:"
  echo "  scripts/dr/snapshot-live-state.sh > k8s-cluster/dr/SNAPSHOT-\$(date -u +%Y-%m-%d).md"
  exit 1
fi
