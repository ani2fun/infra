#!/usr/bin/env bash
# Destroy the lab completely.
#
# Deletes the dblab namespace, which takes the PVCs with it. local-path's reclaim policy is
# Delete, so the PersistentVolumes and the actual directories on wk-1 go too — this genuinely
# reclaims the disk, it does not just detach it.
#
# EVERYTHING GOES: seed data, generated credentials, Kafka topics, the lot. That is the point.
# All of it is reproducible from lab-up.sh.
#
# Bytebase is NOT touched — it lives in its own namespace. Instances registered in its UI will
# simply show as unreachable until the lab comes back.
#
#   deploy/apps/dblab/scripts/lab-nuke.sh          # asks first
#   deploy/apps/dblab/scripts/lab-nuke.sh --yes    # for scripts
set -euo pipefail

ns=dblab
assume_yes=false
[ "${1:-}" = "--yes" ] && assume_yes=true

if ! kubectl get ns "$ns" >/dev/null 2>&1; then
  echo "Namespace $ns does not exist — nothing to nuke."
  exit 0
fi

echo "=== about to destroy ==="
kubectl -n "$ns" get deploy,pvc --no-headers 2>/dev/null | sed 's/^/  /' || true
echo
echo "This deletes the namespace, every PVC in it, and the underlying data on wk-1."

if [ "$assume_yes" != true ]; then
  printf 'Type the namespace name (%s) to confirm: ' "$ns"
  read -r answer
  if [ "$answer" != "$ns" ]; then
    echo "Aborted — nothing was deleted."
    exit 1
  fi
fi

echo
echo "=== deleting namespace $ns ==="
kubectl delete ns "$ns" --wait=true

echo
echo "=== confirming the PVs are gone ==="
remaining=$(kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="'"$ns"'")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -c . || true)
if [ "${remaining:-0}" -eq 0 ]; then
  echo "  no PersistentVolumes left for $ns — disk reclaimed"
else
  echo "  WARNING: $remaining PV(s) still reference $ns; check with 'kubectl get pv'"
fi

echo
echo "Gone. Rebuild any time with: deploy/apps/dblab/scripts/lab-up.sh"
