# Homelab Infrastructure

Personal Kubernetes homelab built on four Ubuntu 24.04 machines (three home
nodes plus one Contabo edge VPS), connected by a WireGuard mesh and running
K3s with Calico, Traefik, cert-manager, Argo CD, Sealed Secrets, PostgreSQL,
and Keycloak.

## Where to start

Everything lives under [`deploy/`](deploy/). It is the single source of
truth -- both for what Argo CD syncs today and for what an operator needs
to rebuild the cluster from cold metal.

- [`deploy/apps/`](deploy/apps/) -- application manifests Argo CD syncs
  (codefolio, dsa-tracker, piston, plus a `dummy-app-template` reference).
- [`deploy/platform/`](deploy/platform/) -- platform service manifests
  and install scripts (traefik, cert-manager, sealed-secrets, argocd,
  postgresql). **Reference / rebuild only -- not Argo-synced.**
- [`deploy/dr/`](deploy/dr/) -- disaster-recovery pack: runbook, frozen
  snapshot, gates, secret-recovery decision tree.
- [`deploy/inventory/`](deploy/inventory/) -- nodes, namespaces, network,
  workload catalog. Reference data.

For first-time orientation: skim [`deploy/dr/README.md`](deploy/dr/README.md),
then [`deploy/dr/RUNBOOK.md`](deploy/dr/RUNBOOK.md). For the live cluster
state, consult [`deploy/dr/SNAPSHOT.md`](deploy/dr/SNAPSHOT.md).
