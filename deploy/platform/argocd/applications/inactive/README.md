# Inactive Argo Applications

Application manifests parked here are **not** applied by `configure-argocd.sh`
— it runs `kubectl apply -f applications/` (non-recursive), so this subdirectory
is skipped. Park an app here (instead of deleting its `Application` YAML) when
you want to pull it out of GitOps but keep the definition for an easy revival:
move the file up to `applications/` and re-run `configure-argocd.sh`.

_No apps are currently parked._ dsa-tracker was retired and removed outright
(its `Application` and `deploy/apps/dsa-tracker/` manifests deleted, not parked)
on 2026-06-15; piston was retired earlier. Neither is in use.
