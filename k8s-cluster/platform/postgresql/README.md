# PostgreSQL

This folder is a direct snapshot of the repo-managed PostgreSQL deployment plus a small helper script for the required node and namespace labels.

## Important notes

- `2-secret.yaml` still contains placeholder values and must be replaced before apply.
- The docs place PostgreSQL on `wk-1` through node label `kakde.eu/postgresql=true`.
- Production application access is granted through namespace label `kakde.eu/postgresql-access=true`.
- The actual live database contents and any drift from these manifests still need a live export.

