# PostgreSQL (`databases-prod`)

Single-instance PostgreSQL StatefulSet for internal cluster use. **Not**
exposed publicly; **not** managed by Argo CD (one-shot bootstrap).

## Design

- Kubernetes: K3s with Calico VXLAN
- Pinned to `wk-1` via node label `kakde.eu/postgresql=true`
- `local-path` storage class, 80Gi PVC -- single-node storage model
- Access only via ClusterIP service `postgresql.databases-prod.svc.cluster.local:5432`
- Application namespaces grant access by labeling themselves
  `kakde.eu/postgresql-access=true`; the NetworkPolicy enforces this

## Files in this directory

| File | Purpose |
|---|---|
| `1-namespace.yaml` | Creates the `databases-prod` namespace |
| `2-secret.yaml` | Superuser password + app DB name/user/password (placeholders -- edit before apply) |
| `3-init-configmap.yaml` | First-init script: create app role + DB + grants |
| `4-services.yaml` | `postgresql-hl` (headless, StatefulSet identity) + `postgresql` (ClusterIP) |
| `5-networkpolicy.yaml` | Default-deny + allow from labeled namespaces |
| `6-statefulset.yaml` | Postgres 17.9 single replica with 80Gi PVC, probes, node selector |
| `label-access.sh` | Helper: stamps the node label and the `apps-prod` access label |
| `docs/` | Legacy docs folder; content merged into this README |

The init ConfigMap runs **only on first PVC initialization**. Changing
the Secret later does NOT change the live PostgreSQL role password --
update via `ALTER ROLE ... WITH PASSWORD '...'`.

## Prerequisites

```bash
kubectl label node wk-1 kakde.eu/postgresql=true --overwrite
kubectl label namespace apps-prod kakde.eu/postgresql-access=true --overwrite
```

(`label-access.sh` does both.)

Then edit `2-secret.yaml` to fill in real passwords. The `postgresql-auth`
plaintext lives in your password manager; the recovery procedure is
documented in [`../../dr/secret-recovery.md`](../../dr/secret-recovery.md).

## Apply

```bash
kubectl apply -f 1-namespace.yaml
kubectl apply -f 2-secret.yaml
kubectl apply -f 3-init-configmap.yaml
kubectl apply -f 4-services.yaml
kubectl apply -f 5-networkpolicy.yaml
kubectl apply -f 6-statefulset.yaml
```

## Verify

```bash
kubectl -n databases-prod get all,pvc,configmap,secret,networkpolicy
kubectl -n databases-prod rollout status statefulset/postgresql --timeout=300s
kubectl -n databases-prod get pod postgresql-0 -o wide   # scheduled on wk-1
kubectl -n databases-prod logs postgresql-0 | tail -n 80 # no permission errors
```

App login test:

```bash
kubectl -n databases-prod exec -it postgresql-0 -- sh -lc \
  'export PGPASSWORD="$APP_DB_PASSWORD"; \
   psql -v ON_ERROR_STOP=1 -h postgresql -U "$APP_DB_USER" -d "$APP_DB_NAME" \
        -c "select current_database(), current_user;"'
```

Expected: `current_database = appdb`, `current_user = appuser`.

## Connection details for in-cluster apps

- Host: `postgresql.databases-prod.svc.cluster.local`
- Port: `5432`
- Database: `appdb` (or whatever you set in `2-secret.yaml`)
- User: `appuser`
- Password: from `2-secret.yaml`

## Backup and restore

PostgreSQL data is **not** in Git and **not** auto-backed-up. Loss of
`wk-1`'s root disk = total data loss unless you keep external backups.

Take logical dumps with the helpers:

```bash
# Periodic backup (output goes wherever you point it: encrypted USB, NAS, etc.)
scripts/dr/postgres-backup.sh /path/to/secure/dir/

# Restore on a freshly-installed StatefulSet
scripts/dr/postgres-restore.sh /path/to/postgres-backup-YYYYMMDDTHHMMSSZ.tar.gz
```

Both scripts use `pg_dumpall --globals-only` for roles plus `pg_dump -Fc`
per non-template database. The backup tarball includes an inventory file
listing estimated row counts so the restore can sanity-check itself.

For the operator runbook, see [`../../dr/RUNBOOK.md`](../../dr/RUNBOOK.md)
Layer 8.

## Password rotation

Changing the Kubernetes Secret does NOT update the live PostgreSQL role
password. After updating the Secret value:

```sql
ALTER ROLE appuser WITH LOGIN PASSWORD 'new-password';
```

Operational rule: Secret value = intended credential; PostgreSQL internal
role = actual credential. Both must match.

## Troubleshooting

**Pod starts but app login fails.** App role/database probably wasn't
created on first init, or the Secret password drifted from the live DB
password. Connect as `postgres` and `CREATE`/`ALTER` the role explicitly,
then re-test.

**Init script changes don't take effect.** PVC already contains an
initialized data directory. The init script only runs on an empty PVC.
If you really want to re-bootstrap: delete the StatefulSet, delete the
PVC, reapply.

**`Operation not permitted` on `chown` during startup.** Too-restrictive
container `securityContext`. The current StatefulSet keeps only pod-level
`seccompProfile: RuntimeDefault` -- do not re-add capability drops or
`fsGroup` rules that prevent the postgres entrypoint from fixing
ownership.

## Full destroy (data loss)

Use only if you want to wipe PostgreSQL and its data:

```bash
kubectl -n databases-prod delete statefulset postgresql
kubectl -n databases-prod delete service postgresql postgresql-hl
kubectl -n databases-prod delete configmap postgresql-init
kubectl -n databases-prod delete secret postgresql-auth
kubectl -n databases-prod delete networkpolicy --all
kubectl -n databases-prod delete pvc data-postgresql-0
kubectl delete namespace databases-prod
```

Deleting the PVC deletes the database data.
