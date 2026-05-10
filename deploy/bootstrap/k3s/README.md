# K3s + Calico bootstrap

These scripts follow `_docs/setup-k3s-with-calico-vxlan.md`.

## Current documented cluster settings

- K3s version: `v1.35.1+k3s1`
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

## Sensitive input

Agent install scripts require `K3S_TOKEN` from `/var/lib/rancher/k3s/server/node-token` on `ms-1`.

