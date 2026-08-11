#!/usr/bin/env bash
# Bring the polyglot database lab up, then seed it.
#
# Safe to run repeatedly: the credentials Secret is generated only if missing, manifests are
# applied declaratively, and every seed script is idempotent.
#
#   deploy/apps/dblab/scripts/lab-up.sh
#
# Roughly 6 GiB of requests land on wk-1. Cassandra and Elasticsearch dominate the startup
# time — a cold first run takes several minutes, almost all of it waiting for Cassandra.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
ns=dblab

echo "=== 1/5  namespace + auto-stop deadline ==="
kubectl apply -f "$app_dir/base/namespace.yaml"

# The dblab-autostop CronJob scales the lab to zero once this absolute deadline passes, so a
# forgotten lab does not sit on ~3.8 GiB of wk-1 indefinitely. Set BEFORE the engines start, not
# after seeding: if this script dies halfway, the half-built lab still gets cleaned up.
#
# Override the window with LAB_TTL_HOURS, or disable auto-stop entirely with:
#   kubectl -n dblab delete configmap dblab-lifecycle
ttl_hours="${LAB_TTL_HOURS:-4}"
deadline=$(( $(date +%s) + ttl_hours * 3600 ))
kubectl -n "$ns" create configmap dblab-lifecycle \
  --from-literal=shutdown-after="$deadline" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "auto-stop at $(date -r "$deadline" 2>/dev/null || date -d "@$deadline" 2>/dev/null || echo "epoch $deadline") (${ttl_hours}h)"

echo
echo "=== 2/5  credentials ==="
# Generated here rather than committed: nothing in this lab is worth sealing, and keeping the
# passwords out of git means `lab-nuke.sh` really does leave no trace. Read them back with:
#   kubectl -n dblab get secret dblab-credentials -o jsonpath='{.data.postgres-password}' | base64 -d
if kubectl -n "$ns" get secret dblab-credentials >/dev/null 2>&1; then
  echo "dblab-credentials already exists — keeping the current passwords"
else
  gen() { head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24; }
  kubectl -n "$ns" create secret generic dblab-credentials \
    --from-literal=postgres-user=labadmin \
    --from-literal=postgres-password="$(gen)" \
    --from-literal=mongo-user=labadmin \
    --from-literal=mongo-password="$(gen)" \
    --from-literal=redis-password="$(gen)" \
    --from-literal=rabbitmq-user=labadmin \
    --from-literal=rabbitmq-password="$(gen)" \
    --from-literal=cassandra-user=cassandra \
    --from-literal=cassandra-password=cassandra
  echo "generated dblab-credentials"
  echo "  NOTE: cassandra keeps its built-in cassandra/cassandra superuser — the image creates"
  echo "        that account itself, so it cannot be randomised here."
fi

echo
echo "=== 3/5  engines ==="
kubectl apply -k "$app_dir/base"

echo
echo "=== 4/5  waiting for engines ==="
# Cassandra gets the longest budget; its startupProbe alone allows ~6.5 minutes.
for d in postgres mongodb redis dynamodb-local rabbitmq kafka kafbat-ui elasticsearch cassandra; do
  printf '  %-16s ' "$d"
  if kubectl -n "$ns" rollout status "deploy/$d" --timeout=600s >/dev/null 2>&1; then
    echo "ready"
  else
    echo "NOT READY (continuing; check with: kubectl -n $ns describe deploy/$d)"
  fi
done

echo
echo "=== 5/5  seeding ==="
# A completed Job's pod template is immutable, so the previous run must go before re-applying.
kubectl -n "$ns" delete job -l app.kubernetes.io/component=seed --ignore-not-found >/dev/null
kubectl apply -k "$app_dir/seed"

for j in seed-postgres seed-mongodb seed-redis seed-elasticsearch seed-dynamodb seed-kafka seed-rabbitmq seed-cassandra; do
  printf '  %-20s ' "$j"
  if kubectl -n "$ns" wait --for=condition=complete "job/$j" --timeout=900s >/dev/null 2>&1; then
    echo "done"
  else
    echo "FAILED (logs: kubectl -n $ns logs job/$j)"
  fi
done

echo
echo "Lab is up. Verify with:  $script_dir/lab-verify.sh"
echo "Connection details for Bytebase 'Create Instance' are in deploy/apps/bytebase/OPERATIONS.md"
