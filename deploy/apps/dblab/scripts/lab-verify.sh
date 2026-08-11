#!/usr/bin/env bash
# Independently confirm every engine is up AND seeded.
#
# Deliberately uses each engine's NATIVE client via `kubectl exec` and never goes through
# Bytebase. That separation is the whole value: when something breaks, this tells you whether
# the database is at fault or the client is.
#
# Prints a pass/fail table and exits non-zero if anything failed.
#
#   deploy/apps/dblab/scripts/lab-verify.sh
set -uo pipefail   # NOT -e: a failing check must be recorded, not abort the run

ns=dblab
fails=0
results=""

secret() { kubectl -n "$ns" get secret dblab-credentials -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d; }

record() { # name expected actual
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ] || { [ "$expected" = "nonzero" ] && [ -n "$actual" ] && [ "$actual" != "0" ]; }; then
    results="${results}  PASS  ${name}  (${actual})\n"
  else
    results="${results}  FAIL  ${name}  (got '${actual}', wanted '${expected}')\n"
    fails=$((fails + 1))
  fi
}

if ! kubectl get ns "$ns" >/dev/null 2>&1; then
  echo "Namespace $ns does not exist. Run lab-up.sh first."
  exit 1
fi

echo "=== checking engines with their own native clients ==="

PG_USER="$(secret postgres-user)"; PG_PASS="$(secret postgres-password)"
out=$(kubectl -n "$ns" exec deploy/postgres -- env PGPASSWORD="$PG_PASS" \
        psql -U "$PG_USER" -d labdb -tAc "SELECT count(*) FROM orders" 2>/dev/null | tr -d '[:space:]')
record "postgres    orders rowcount" "40" "$out"

MG_USER="$(secret mongo-user)"; MG_PASS="$(secret mongo-password)"
out=$(kubectl -n "$ns" exec deploy/mongodb -- mongosh \
        "mongodb://$MG_USER:$MG_PASS@localhost:27017/labdb?authSource=admin" \
        --quiet --eval 'db.orders.countDocuments()' 2>/dev/null | tr -d '[:space:]')
record "mongodb     orders documents" "30" "$out"

RD_PASS="$(secret redis-password)"
out=$(kubectl -n "$ns" exec deploy/redis -- sh -c \
        "redis-cli -a '$RD_PASS' --no-auth-warning DBSIZE" 2>/dev/null | tr -d '[:space:]')
record "redis       dbsize" "nonzero" "$out"

out=$(kubectl -n "$ns" exec deploy/elasticsearch -- \
        curl -s "http://localhost:9200/products/_count" 2>/dev/null \
        | sed -n 's/.*"count":\([0-9]*\).*/\1/p')
record "elasticsearch products count" "30" "$out"

CS_USER="$(secret cassandra-user)"; CS_PASS="$(secret cassandra-password)"
out=$(kubectl -n "$ns" exec deploy/cassandra -- cqlsh -u "$CS_USER" -p "$CS_PASS" \
        -e "SELECT count(*) FROM lab.orders_by_customer" 2>/dev/null \
        | sed -n '4p' | tr -d '[:space:]')
record "cassandra   orders_by_customer" "20" "$out"

# The dynamodb-local image is a bare JRE with no AWS CLI and no usable shell, so the check runs
# in a throwaway pod built from the same image the seed Job uses.
#
# --attach --quiet, deliberately NOT -i: with stdin attached this hangs when the script itself
# arrives on stdin (e.g. `ssh host bash -s < lab-verify.sh`), which silently truncates the whole
# run at this line.
out=$(kubectl -n "$ns" run "ddb-verify-$$" --rm --restart=Never --attach --quiet \
        --image=amazon/aws-cli:2.31.9 \
        --env AWS_ACCESS_KEY_ID=dummy --env AWS_SECRET_ACCESS_KEY=dummy --env AWS_DEFAULT_REGION=eu-central-1 \
        --command -- /bin/sh -c \
        'aws --endpoint-url http://dynamodb-local:8000 dynamodb scan --table-name Orders --select COUNT --query Count --output text' \
        2>/dev/null | tr -d '[:space:]\r')
record "dynamodb    Orders item count" "24" "$out"

out=$(kubectl -n "$ns" exec deploy/kafka -- \
        /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2>/dev/null \
        | grep -c -E '^(orders|customer-events)$' | tr -d '[:space:]')
record "kafka       seeded topics" "2" "$out"

RB_USER="$(secret rabbitmq-user)"; RB_PASS="$(secret rabbitmq-password)"
out=$(kubectl -n "$ns" exec deploy/rabbitmq -- rabbitmqctl list_queues --quiet --formatter json 2>/dev/null \
        | grep -o '"name"' | grep -c . | tr -d '[:space:]')
record "rabbitmq    declared queues" "nonzero" "$out"

echo
echo "=== results ==="
printf "%b" "$results"
echo
if [ "$fails" -eq 0 ]; then
  echo "All checks passed."
else
  echo "$fails check(s) FAILED."
fi
exit "$fails"
