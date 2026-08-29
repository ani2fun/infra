# Inactive Argo Applications

Application manifests parked here are **not** applied by `configure-argocd.sh`
— it runs `kubectl apply -f applications/` (non-recursive), so this subdirectory
is skipped. Park an app here (instead of deleting its `Application` YAML) when
you want to pull it out of GitOps but keep the definition for an easy revival:
move the file up to `applications/` and re-run `configure-argocd.sh`.

Currently parked:

- **cortex** + **cortex-tutor** (2026-07-15) — archived, superseded by the
  Synapse rebuild (synapse.kakde.eu). Their manifests under `deploy/apps/cortex/`
  and `deploy/apps/cortex-tutor/` are kept intact for future reference; the
  `Application` objects were deleted from the cluster with cascade, the shared
  Postgres `cortex` database was dumped (see the cortex archive dir on the
  workstation) and dropped. To revive: recreate the DB from the dump
  (`bootstrap.sql` + restore), move these files up, re-run `configure-argocd.sh`.
  The `apps-prod` Keycloak realm and its `cortex-web` client were left in place
  (no resource cost).

  **Reviving cortex now also requires restoring an executor.** The shared
  `go-judge` app was retired on 2026-08-20 (see below). The note that used to
  sit here — "shared `go-judge` stays (codefolio uses it)" — was already wrong
  when it was written: codefolio dropped `EXECUTOR_URL` in `fa2380d`
  (2026-06-08) when it was trimmed to a static site, five weeks earlier. Cortex
  still carries `EXECUTOR_URL: http://go-judge:5050`
  (`deploy/apps/cortex/base/deployment.yaml`) and a
  `go-judge-allow-ingress-from-cortex` policy targeting pods that no longer
  exist, so a revival must first restore the executor —
  `git show 4ff826e:deploy/apps/go-judge` has the deleted tree — or
  repoint cortex at another sandbox.

Previously retired outright (manifests deleted, not parked): dsa-tracker
(2026-06-15); piston earlier; the shared `go-judge` executor (2026-08-20, no
consumer since codefolio went static). None are in use.
