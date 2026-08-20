# K3s + Calico bootstrap

These scripts install K3s with Calico VXLAN over the WireGuard mesh, on cold metal.
For an **in-place version bump of a cluster that is already running**, do not use these
scripts directly — follow [`../../dr/UPGRADE.md`](../../dr/UPGRADE.md), which wraps them
with the cordon, drain, backup, and verification steps they deliberately omit.

## Current documented cluster settings

- K3s version: `v1.36.3+k3s1`
- Server node: `ms-1`
- Agents: `wk-1`, `wk-2`, `vm-1` (`ctb-edge-1` in docs)
- Pod CIDR: `10.42.0.0/16`
- Service CIDR: `10.43.0.0/16`
- Flannel: disabled
- K3s network policy: disabled
- Packaged Traefik: disabled
- ServiceLB: disabled
- CNI: Calico VXLAN via Tigera operator
- Calico MTU: `1370`
- Node autodetection: Kubernetes `NodeInternalIP` so WireGuard IPs become node internal IPs

## Apply order

1. `create-k3s-resolv-conf.sh` on every node
2. `install-server-ms-1.sh` on `ms-1`
3. `install-calico.sh` on `ms-1`
4. `install-agent-wk-1.sh`, `install-agent-wk-2.sh`, `install-agent-vm-1.sh`
5. `apply-node-placement.sh`

## Upgrading an existing cluster

The version above is the single source of truth for what is deployed. To move the cluster
to a new K3s release, bump `INSTALL_K3S_VERSION` in all four install scripts **and** the
version line above, commit, then work through [`../../dr/UPGRADE.md`](../../dr/UPGRADE.md)
node by node. That runbook re-runs these same scripts unmodified — re-running an install
script with a new version pin and identical `INSTALL_K3S_EXEC` is how K3s upgrades in place.

Note that every K3s flag lives in `INSTALL_K3S_EXEC` and is baked into the systemd unit at
install time; there is no `/etc/rancher/k3s/config.yaml` on any node. The installer rewrites
the unit on every run, so any hand-edit made directly on a node is silently lost.

`install-calico.sh` uses `kubectl create` and is bootstrap-only — it cannot upgrade Calico.

## Sensitive input

Agent install scripts require `K3S_TOKEN` from `/var/lib/rancher/k3s/server/node-token` on `ms-1`.

