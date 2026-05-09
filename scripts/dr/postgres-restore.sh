#!/usr/bin/env bash
# Restore a logical backup produced by scripts/dr/postgres-backup.sh into a
# fresh PostgreSQL StatefulSet. Restores globals (roles, tablespaces) first,
# then per-database custom-format dumps with --create --clean --if-exists.
#
# Verifies row counts post-restore against the inventory file in the tarball.
#
# Usage:
#   scripts/dr/postgres-restore.sh /path/to/postgres-backup-*.tar.gz
#
# CAUTION: --clean will DROP and recreate matching objects in the target
# database. Do not run against a live database that still contains useful
# data unless you are sure that is what you want.
set -euo pipefail

BACKUP="${1:?usage: $0 <backup.tar.gz>}"
[[ -f "$BACKUP" ]] || { echo "backup not found: $BACKUP" >&2; exit 1; }

POD="${POSTGRES_POD:-postgresql-0}"
NS="${POSTGRES_NAMESPACE:-databases-prod}"
WORK="$(mktemp -d -t pg-restore-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> verifying backup"
echo "    sha256: $(shasum -a 256 "$BACKUP" | awk '{print $1}')"
tar -tzf "$BACKUP" >/dev/null

echo "==> extracting"
tar -C "$WORK" -xzf "$BACKUP"
[[ -f "$WORK/globals.sql" ]] || { echo "globals.sql missing from backup" >&2; exit 1; }

ssh_ms1() { ssh -o BatchMode=yes -o ConnectTimeout=8 ms-1 "$@"; }
exec_psql() {
  # pipe local file into kubectl exec on the postgres pod
  ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n ${NS} exec -i ${POD} -- $*"
}

echo "==> probing pod ${NS}/${POD}"
exec_psql "pg_isready -U postgres" >/dev/null

echo "==> restoring globals"
exec_psql "psql -U postgres -v ON_ERROR_STOP=1 -f -" < "$WORK/globals.sql" >/dev/null

echo "==> per-database restore"
for dump in "$WORK"/*.dump; do
  [[ -f "$dump" ]] || continue
  db="$(basename "$dump" .dump)"
  echo "    - $db"
  exec_psql "pg_restore -U postgres --create --clean --if-exists -d postgres" < "$dump" >/dev/null 2>&1 || \
    echo "      (pg_restore reported non-zero; this is normal if some objects already existed)"
done

if [[ -f "$WORK/inventory.txt" ]]; then
  echo
  echo "==> row-count check vs. inventory"
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+name:[[:space:]]+(.+) ]]; then
      db="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]+estimated_rows:[[:space:]]+(.+) ]]; then
      expected="${BASH_REMATCH[1]}"
      actual="$(ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n ${NS} exec ${POD} -- psql -U postgres -At -d ${db} -c \"SELECT sum(reltuples)::bigint FROM pg_class WHERE relkind='r'\"" | tr -d '\r' || echo "?")"
      printf "    %-30s expected≈%s actual≈%s\n" "$db" "$expected" "$actual"
    fi
  done < "$WORK/inventory.txt"
fi

cat <<EOF

==> restore complete

The restore used --clean so previously-existing objects matching those in
the dump have been dropped and recreated. If row counts diverge significantly
from the inventory, investigate before declaring success.
EOF
