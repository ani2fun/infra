# Homelab Infrastructure

Personal Kubernetes homelab built on four Ubuntu 24.04 machines (three home
nodes plus one Contabo edge VPS), connected by a WireGuard mesh and running
K3s with Calico, Traefik, cert-manager, Argo CD, Sealed Secrets, PostgreSQL,
and Keycloak.

## Where to start

- **Cluster overview and rebuild sequence** — [k8s-cluster/README.md](k8s-cluster/README.md)
- **Disaster-recovery pack** (runbook, gates, snapshot, secret recovery) —
  [k8s-cluster/dr/README.md](k8s-cluster/dr/README.md)
- **Frozen state snapshot** (versions, image digests, node facts) —
  [k8s-cluster/dr/SNAPSHOT.md](k8s-cluster/dr/SNAPSHOT.md)
- **Inventory** (nodes, namespaces, network, workloads) —
  [k8s-cluster/inventory/](k8s-cluster/inventory/)
- **Layer manifests and install scripts** — [k8s-cluster/](k8s-cluster/)
- **Argo CD Application definitions** — [argocd/apps/](argocd/apps/)
- **Application manifests currently tracked by Argo CD** — [deploy/](deploy/)

## Layout note

The repo is mid-migration. The `k8s-cluster/` tree is the target architecture
and holds the recovery pack; `deploy/` is the manifest tree Argo CD currently
syncs from. Both are kept in lockstep — do not move app manifests between
them without changing the Argo CD source paths.
