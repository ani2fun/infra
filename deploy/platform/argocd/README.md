# Argo CD

This folder is the Argo CD install: the upstream manifest at one pinned tag (**v3.6.1**) plus this
cluster's patches, in [`kustomization.yaml`](kustomization.yaml).

- install into namespace `argocd` with `install-argocd.sh` (`kubectl apply --server-side -k`)
- pin workloads to `wk-2` through `workload=argocd`
- disable internal TLS on `argocd-server`
- expose the UI at `https://argocd.kakde.eu` through standard Kubernetes `Ingress`
- keep codefolio, synapse, synapse-go-judge, synapse-tts, bytebase and monitoring as `Application` resources pointing at this repo
- manage those `Application` resources from git too: the `applications` root (`applications/root.yaml`) syncs the `applications/` folder (non-recursive, no prune), so adding an app is a push. `configure-argocd.sh` applies the folder once on a fresh cluster, which creates the root; from then on the root owns it

## Files

| File | What it does |
|---|---|
| `kustomization.yaml` | Pins the upstream `install.yaml` tag and patches it: `nodeSelector workload=argocd`, 2 repo-servers, `server.insecure`, and a Traefik Ingress health check in `argocd-cm`. |
| `patches/resources.yaml` | Requests and limits for every Argo CD container (upstream ships none). |
| `patches/argocd-cm.yaml` | The Traefik Ingress health check. Without it, every Ingress (and so every app) stays `Progressing`, because Traefik here does not publish `status.loadBalancer`. |
| `install-argocd.sh` | Install or upgrade. Safe to re-run. |
| `configure-argocd.sh` | One-time wiring on a fresh cluster: node label, UI Ingress, the `applications` root. |

## Upgrading

1. Read the upstream notes for every minor version you cross:
   `https://github.com/argoproj/argo-cd/blob/<new-tag>/docs/operator-manual/upgrading/<from>-<to>.md`.
2. Bump the tag in `kustomization.yaml`.
3. Copy this folder to `ms-1` and preview: `kubectl diff --server-side --force-conflicts -k <folder>`.
   Expect image tags and CRD text to change. Anything else (lost `nodeSelector`, resources,
   `argocd-cm` keys) means a patch no longer applies.
4. Run `install-argocd.sh`, then check `kubectl get application -n argocd` shows all `Synced/Healthy`.

Never install from the `stable` URL. A rebuild must get the same version as the running cluster.

## Why the version is pinned at v3.6+ (incident, Sep–Nov 2026)

`wk-2` rebooted about weekly after kernel updates (unattended-upgrades, 04:30, no drain). Each time,
the v3.3.3 repo-server init container `copyutil` re-ran `ln -s` into an `emptyDir` that survived
the reboot, and failed with `/bin/ln: Already exists`. It crash-looped until someone ran
`kubectl -n argocd rollout restart deploy argocd-repo-server`. Both repo-servers live on `wk-2`,
so both failed together, every Application showed `Sync: Unknown`, and no deploy happened.

Two independent fixes (2026-11-18):

- v3.6.1's init container uses `ln -sf`, so it is safe to re-run.
- kured ([`../kured/`](../kured/kustomization.yaml)) drains a worker before a kernel reboot, so
  pods come back as new pods with clean volumes.

The Grafana rules `argocd-component-unhealthy` and `pod-crashloop`
(`deploy/apps/monitoring/base/grafana-alerting-configmap.yaml`) email when this class of failure
returns.

