# `deploy/`

Single source of truth for the homelab cluster -- both for Argo CD's
live sync and for an operator-driven rebuild from cold metal.

## Layout

| Folder | What lives here | Touched by Argo CD? |
|---|---|---|
| `apps/` | Application manifests with `base/` + `overlays/{dev,prod}/` per app. Argo CD `Application` objects point at `apps/<name>/overlays/prod/` for the three GitOps-tracked apps (codefolio, dsa-tracker, piston). Also holds `keycloak/` and `whoami/`, which are deployed manually with `kubectl apply -k`, plus the `dummy-app-template` reference. | **Yes** for the three GitOps apps; **no** for keycloak/whoami |
| `bootstrap/` | Cold-metal bootstrap scripts and configs for host OS prep, K3s install, and WireGuard mesh setup. Run from the operator's laptop on a fresh node. | No |
| `platform/` | Manifests and install scripts for cluster platform services (traefik, cert-manager, sealed-secrets, argocd, postgresql). Used during rebuild; the `applications/` subfolder under `platform/argocd/` defines the Argo CD `Application` resources themselves. | **No** -- these are reference / one-shot bootstrap material. Do NOT add them to a kustomize root or another Argo Application. |
| `dr/` | Disaster-recovery pack: `RUNBOOK.md`, `SNAPSHOT.md`, `gates.md`, `secret-recovery.md`, sealed-secrets backup procedure, keycloak realm export procedure. | No |
| `inventory/` | Reference data: `network.yaml`, `nodes.yaml`, `namespaces.yaml`, `workloads.yaml`. | No |

## How a release reaches the cluster

1. The upstream app repo (e.g. [`ani2fun/codefolio`](https://github.com/ani2fun/codefolio))
   builds an image, then a CI step clones this repo and bumps the
   `images:` tag inside `deploy/apps/<app>/overlays/prod/kustomization.yaml`.
2. CI commits and pushes back to `main`.
3. Argo CD's `Application` (declared in
   `deploy/platform/argocd/applications/<app>.yaml` with
   `path: deploy/apps/<app>/overlays/prod`) auto-syncs the change.

`piston` has no upstream CI bumper -- update its image manually if you
need to roll it forward.

## Where to start

- Operator rebuild: [`dr/RUNBOOK.md`](dr/RUNBOOK.md).
- What versions/images are running: [`dr/SNAPSHOT.md`](dr/SNAPSHOT.md).
- Adding a new GitOps-managed app: copy [`apps/dummy-app-template/`](apps/dummy-app-template/),
  then drop a matching `Application` YAML into
  [`platform/argocd/applications/`](platform/argocd/applications/).
- Cold-metal rebuild starts at [`bootstrap/`](bootstrap/) -- host-prep,
  WireGuard mesh, K3s + Calico install. The runbook walks through it
  layer by layer.
