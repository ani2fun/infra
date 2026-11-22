#!/usr/bin/env bash
# Compare the live cluster's headline versions against a snapshot.
# Reports drift so you can refresh the snapshot before it goes stale in DR.
#
# Defaults to deploy/dr/SNAPSHOT.md, the frozen 2026-05-09 anchor. That file is
# never edited, so after any upgrade it reports drift permanently and by design
# — it answers "how far from the original build are we?". To check the cluster
# against the CURRENT expected state instead, pass the newest dated snapshot.
#
# Read-only. Exits 0 on no drift, 1 on drift.
#
# Usage:
#   scripts/dr/verify-snapshot.sh                                  # vs the frozen anchor
#   scripts/dr/verify-snapshot.sh deploy/dr/SNAPSHOT-2026-11-19.md # vs the latest capture
set -euo pipefail

SNAPSHOT="${1:-$(dirname "$0")/../../deploy/dr/SNAPSHOT.md}"
if [[ ! -f "$SNAPSHOT" ]]; then
  echo "snapshot not found: $SNAPSHOT" >&2
  exit 2
fi

ssh_ms1() { ssh -o BatchMode=yes -o ConnectTimeout=8 ms-1 "$@"; }
kubectl_ms1() { ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $*"; }

# Pull a "Component | Version |" table row out of the snapshot. Returns the
# Version cell.
#
# The trim MUST strip backticks as well as whitespace: SNAPSHOT.md writes every
# version as markdown code (`v1.35.1+k3s1`), so trimming whitespace alone leaves
# the backticks attached and the comparison can NEVER match. That made this
# script report drift between two identical versions on every single run, which
# is the fastest way to train an operator to ignore a drift detector.
snap_version() {
  local component="$1"
  awk -v c="$component" -F'|' '
    /^\| Component \| Version /{ in_table=1; next }
    /^\|---/ && in_table { next }
    /^[^|]/ { in_table=0 }
    in_table {
      gsub(/^[ \t`]+|[ \t`]+$/, "", $2)
      gsub(/^[ \t`]+|[ \t`]+$/, "", $3)
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

# --- Git pin vs live cluster ------------------------------------------------
#
# The install scripts' INSTALL_K3S_VERSION pin is the source of truth for what
# a rebuild would deploy. It can legitimately sit AHEAD of the live cluster
# (U1 bumps it before any node is touched), but if it ever falls BEHIND, a
# rebuild from the DR pack would silently downgrade the cluster.
#
# Returns the pinned version, e.g. v1.37.2+k3s1
pinned_k3s() {
  sed -n 's/.*INSTALL_K3S_VERSION:-\([^}]*\)}.*/\1/p' \
    "$(dirname "$0")/../../deploy/bootstrap/k3s/install-server-ms-1.sh" | head -1
}

# Normalise a K3s version into a purely dotted form that sort -V can order:
#   v1.37.2+k3s1 -> 1.37.2.1
# The k3s build number becomes a fourth component rather than being discarded.
# Dropping it would make v1.37.2+k3s2 and v1.37.2+k3s1 compare EQUAL, so a
# rebuilt patch release — which is exactly the kind of bump that lands without
# a Kubernetes version change — would be invisible to this check.
comparable() { printf '%s' "${1#v}" | sed 's/+k3s\([0-9]*\)$/.\1/'; }

# Highest of two dotted versions, using sort -V (version sort). sort -V orders
# components numerically, so 1.37.10 correctly outranks 1.37.9 where a plain
# string comparison would not.
higher_of() { printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1; }

pin_k3s="$(pinned_k3s)"
pin_sv="$(comparable "$pin_k3s")"
live_sv="$(comparable "$actual_k3s")"

# Severity here is deliberately asymmetric, because the two mismatch directions
# mean opposite things:
#
#   pin > live   An upgrade is staged and not finished. This is the NORMAL state
#                between U1 (bump the pins) and U7 (refresh the pack), so it is
#                INFO, not DRIFT. Marking a documented transient as DRIFT is how
#                you teach an operator to ignore the word — the same reasoning
#                the Argo revision block below spells out. The wording carries
#                the signal instead.
#
#   live > pin   The cluster was upgraded and Git was never updated. A rebuild
#                from the DR pack would install the OLDER version, i.e. silently
#                downgrade the cluster. This is the most dangerous state the
#                script can find, and the only one that fails the run.
#
# An unreadable pin is a third case, not a comparison: if INSTALL_K3S_VERSION
# cannot be extracted, the file a rebuild depends on is broken, so that fails
# too rather than passing quietly.
if [[ -z "$pin_k3s" ]]; then
  printf "  DRIFT %-30s could not read INSTALL_K3S_VERSION from install-server-ms-1.sh\n" "K3s Git pin"
  drift=1
elif [[ "$actual_k3s" == "unknown" ]]; then
  # The live version was already reported as drift by check() above; do not
  # compare against a placeholder and do not double-count it.
  printf "  INFO %-30s skipped — live version unavailable\n" "K3s pin vs live"
elif [[ "$pin_sv" == "$live_sv" ]]; then
  printf "  OK   %-30s = %s (Git and cluster agree)\n" "K3s pin vs live" "$pin_k3s"
elif [[ "$(higher_of "$pin_sv" "$live_sv")" == "$pin_sv" ]]; then
  printf "  INFO %-30s pin=%s is AHEAD of live=%s — upgrade staged, not finished\n" \
    "K3s pin vs live" "$pin_k3s" "$actual_k3s"
  printf "       %-30s finish it, or revert the pin if the upgrade was abandoned\n" ""
else
  printf "  DRIFT %-30s pin=%s is BEHIND live=%s\n" "K3s pin vs live" "$pin_k3s" "$actual_k3s"
  printf "        %-30s a rebuild from this repo would DOWNGRADE the cluster — bump the pin\n" ""
  drift=1
fi

# --- end Git pin vs live ----------------------------------------------------

# cert-manager Helm chart. Matched by grepping the snapshot for the live chart
# string rather than parsing a specific cell — the chart name carries its own
# version (cert-manager-v1.19.1), so presence anywhere in the file is enough.
actual_cm="$(ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm -n cert-manager list -o json 2>/dev/null" | jq -r '.[0].chart' 2>/dev/null || echo unknown)"
if grep -q "$actual_cm" "$SNAPSHOT" 2>/dev/null; then
  printf "  OK   %-30s = %s\n" "cert-manager Helm chart" "$actual_cm"
else
  printf "  DRIFT %-30s actual=%s (not found in snapshot)\n" "cert-manager Helm chart" "$actual_cm"
  drift=1
fi

# Argo CD synced revisions per app
echo
echo "=> Argo CD Application revisions (informational — these move on every commit):"
kubectl_ms1 "get application -n argocd -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.revision}{\"\\n\"}{end}'" | while IFS='=' read -r name rev; do
  [[ -z "$name" ]] && continue
  if grep -q "$rev" "$SNAPSHOT"; then
    printf "  OK   %-25s = %s\n" "$name" "$rev"
  else
    # Labelled INFO, not DRIFT, and deliberately does NOT set drift=1: app
    # revisions advance with every push, so counting them would leave the script
    # permanently failing and the word DRIFT meaning nothing.
    printf "  INFO %-25s at=%s (newer than snapshot)\n" "$name" "$rev"
  fi
done

echo
if [[ $drift -eq 0 ]]; then
  echo "no drift detected"
  exit 0
else
  echo "DRIFT detected. Consider regenerating the snapshot:"
  echo "  scripts/dr/snapshot-live-state.sh > deploy/dr/SNAPSHOT-\$(date -u +%Y-%m-%d).md"
  exit 1
fi
