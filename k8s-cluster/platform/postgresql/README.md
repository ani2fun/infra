# PostgreSQL

This folder is a direct snapshot of the repo-managed PostgreSQL deployment
plus a small helper script for the required node and namespace labels.

## Important notes

- `2-secret.yaml` still contains placeholder values and must be replaced
  before apply. See [`../../dr/secret-recovery.md`](../../dr/secret-recovery.md)
  for the `postgresql-auth` plaintext source on rebuild.
- The docs place PostgreSQL on `wk-1` through node label `kakde.eu/postgresql=true`.
- Production application access is granted through namespace label
  `kakde.eu/postgresql-access=true`.

## Backup and restore

PostgreSQL data is **not** in Git and **not** auto-backed-up. Loss of `wk-1`'s
root disk = total data loss unless you keep external backups.

Take logical dumps with the helper scripts:

```bash
# Periodic backup -- output goes wherever you point it (encrypted USB, NAS, S3 sync target, etc.)
scripts/dr/postgres-backup.sh /path/to/secure/dir/

# Restore on a freshly-installed StatefulSet
scripts/dr/postgres-restore.sh /path/to/postgres-backup-YYYYMMDDTHHMMSSZ.tar.gz
```

Both scripts use `pg_dumpall --globals-only` for roles plus `pg_dump -Fc`
per non-template database. The backup tarball includes an inventory file
listing estimated row counts so the restore can sanity-check itself.

For the operator runbook, see [`../../dr/RUNBOOK.md`](../../dr/RUNBOOK.md)
Layer 8.
