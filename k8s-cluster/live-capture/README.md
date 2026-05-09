# Live capture scripts

These scripts are meant to be run from a workstation that can already SSH to:

- `ms-1`
- `vm-1`
- `wk-1`
- `wk-2`

## What gets captured

- node inventory and labels
- namespaces and namespace labels
- cluster-scoped resources such as ingress classes, storage classes, PVs, and ClusterIssuers
- namespace-scoped workloads for `argocd`, `apps-prod`, `apps-dev`, `databases-prod`, `cert-manager`, and `traefik`
- best-effort discovery of any Keycloak namespace
- host networking, WireGuard config, K3s service units, nftables, iptables, and resolver config

## Secret handling

The collector exports **secret metadata only** by default. It does not dump secret values.

## Recommended follow-up

After collecting output, compare the live manifests against the copied repo manifests in this directory and then promote the live-verified manifests into version control.

## Related: DR snapshotting

For a structured snapshot that pins versions, image digests, Argo CD
revisions, and host facts in a markdown file you can keep in Git, run
`scripts/dr/snapshot-live-state.sh` instead. It calls into this collector
for the per-host details and adds the cluster-wide pin data on top. See
`k8s-cluster/dr/SNAPSHOT.md` for the current frozen reference.

