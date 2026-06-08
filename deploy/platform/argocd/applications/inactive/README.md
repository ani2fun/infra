# Inactive Argo Applications

Application manifests parked here are **not** applied by `configure-argocd.sh`
— it runs `kubectl apply -f applications/` (non-recursive), so this subdirectory
is skipped. The app definitions under `deploy/apps/<name>/` are kept intact.

## dsa-tracker — parked 2026-06-08

No longer in use. Removed from the cluster (Argo `Application` deleted with a
cascade prune of its workloads), but the manifests live on at
`deploy/apps/dsa-tracker/`. Its data (if any) is in the shared Postgres and was
not touched.

To bring it back: move this file up to `applications/` and run
`configure-argocd.sh` (or `kubectl apply -f applications/inactive/dsa-tracker.yaml`).
