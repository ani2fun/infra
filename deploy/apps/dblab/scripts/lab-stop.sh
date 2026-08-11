#!/usr/bin/env bash
# Stop the lab WITHOUT losing anything.
#
# Scales every workload to zero. Frees roughly 6 GiB of RAM on wk-1 within seconds while the
# PVCs, the seed data and the generated credentials all stay exactly where they are — so
# lab-up.sh brings it back in the time it takes the pods to start, with no re-seeding.
#
# Use lab-nuke.sh instead when you want the disk back too.
#
#   deploy/apps/dblab/scripts/lab-stop.sh
set -euo pipefail

ns=dblab

if ! kubectl get ns "$ns" >/dev/null 2>&1; then
  echo "Namespace $ns does not exist — nothing to stop."
  exit 0
fi

echo "=== scaling workloads to zero ==="
kubectl -n "$ns" scale deployment --all --replicas=0

# Clear the auto-stop deadline: the lab is already down, so leaving it would just have the
# CronJob re-scale an idle namespace every 15 minutes. lab-up.sh writes a fresh one.
kubectl -n "$ns" delete configmap dblab-lifecycle --ignore-not-found >/dev/null

echo
echo "=== waiting for engine pods to go ==="
# Scoped to the engines on purpose. `--all` would also wait on the seed Jobs' pods, which sit in
# Completed forever and are never deleted — so the wait would always burn the full timeout.
kubectl -n "$ns" wait --for=delete pod \
  -l 'app.kubernetes.io/part-of=dblab,app.kubernetes.io/component notin (seed)' \
  --timeout=180s 2>/dev/null || true

echo
echo "=== what survives ==="
kubectl -n "$ns" get pvc 2>/dev/null || true
echo
echo "Data and credentials are intact. Restart with: deploy/apps/dblab/scripts/lab-up.sh"
