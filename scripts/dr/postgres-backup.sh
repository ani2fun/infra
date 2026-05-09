#!/usr/bin/env bash
# Logical backup of the homelab PostgreSQL StatefulSet.
#
# Discovers all non-template databases automatically. Captures:
#   - role and tablespace globals via pg_dumpall --globals-only
#   - one custom-format dump per non-template database
#
# Bundles results into a single tarball. Output dir is the caller's
# argument; choose a path on encrypted off-cluster storage.
#
# Read-only against the database. Safe to run during normal operation.
#
# Usage:
#   scripts/dr/postgres-backup.sh /path/to/output/dir
set -euo pipefail

OUT_DIR="${1:?usage: $0 <output-dir>}"
mkdir -p "$OUT_DIR"

POD="${POSTGRES_POD:-postgresql-0}"
NS="${POSTGRES_NAMESPACE:-databases-prod}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d -t pg-backup-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

ssh_ms1() { ssh -o BatchMode=yes -o ConnectTimeout=8 ms-1 "$@"; }
kubectl_exec() {
  ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n ${NS} exec ${POD} -- $*"
}

echo "==> probing pod ${NS}/${POD}"
kubectl_exec "pg_isready -U postgres" >/dev/null
kubectl_exec "psql -U postgres -At -c 'SELECT version();'" | head -1

echo "==> discovering databases"
DBS="$(kubectl_exec "psql -U postgres -At -c \"SELECT datname FROM pg_database WHERE datname NOT IN ('template0','template1','postgres') ORDER BY datname\"")"
DBS="$(echo "$DBS" | tr -d '\r' | grep -v '^$' || true)"
if [[ -z "$DBS" ]]; then
  echo "    (no application databases found; backing up roles only)" >&2
fi
echo "    databases: $(echo "$DBS" | tr '\n' ' ')"

echo "==> dumping role/tablespace globals"
kubectl_exec "pg_dumpall -U postgres --globals-only" > "${WORK}/globals.sql"

echo "==> per-database dumps"
while IFS= read -r db; do
  [[ -z "$db" ]] && continue
  echo "    - $db"
  kubectl_exec "pg_dump -Fc -U postgres -d ${db}" > "${WORK}/${db}.dump"
done <<< "$DBS"

echo "==> recording inventory"
{
  echo "snapshot_time: ${TS}"
  echo "pod: ${NS}/${POD}"
  echo "databases:"
  while IFS= read -r db; do
    [[ -z "$db" ]] && continue
    rows="$(kubectl_exec "psql -U postgres -At -d ${db} -c \"SELECT sum(reltuples)::bigint FROM pg_class WHERE relkind='r'\"" | tr -d '\r' || echo "?")"
    echo "  - name: ${db}"
    echo "    estimated_rows: ${rows}"
  done <<< "$DBS"
} > "${WORK}/inventory.txt"

echo "==> bundling"
out_tar="${OUT_DIR}/postgres-backup-${TS}.tar.gz"
tar -C "${WORK}" -czf "${out_tar}" .
chmod 0600 "${out_tar}"
sha="$(shasum -a 256 "${out_tar}" | awk '{print $1}')"

cat <<EOF

==> backup complete
file:    ${out_tar}
size:    $(du -h "${out_tar}" | awk '{print $1}')
sha256:  ${sha}

inventory:
$(cat "${WORK}/inventory.txt" | sed 's/^/  /')

NEXT STEPS:
  1. Move the tarball to encrypted off-cluster storage.
  2. Record the sha256 above so on restore day you can verify integrity.
  3. Schedule a periodic run via cron / systemd timer (out of scope here).

To restore: scripts/dr/postgres-restore.sh ${out_tar}
EOF
