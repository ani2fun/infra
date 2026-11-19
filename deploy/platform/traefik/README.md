# Traefik edge ingress

Traefik is the sole public ingress controller, running on the edge node (`ctb-edge-1` / `vm-1`).

## Architecture

- Namespace: `traefik`
- Deployment runs with `hostNetwork: true` on the edge node
- Edge node label: `kakde.eu/edge=true`
- Edge node taint: `kakde.eu/edge=true:NoSchedule`
- Ports: 80 (HTTP, redirects to HTTPS) and 443 (HTTPS)
- Security context requires `NET_BIND_SERVICE` for ports below 1024
- Rolling update strategy uses `maxSurge=0` to avoid host port conflicts
- Probes use TCP socket on port 80 (not HTTP admin port)
- ACME data stored at `/var/lib/traefik` on the edge host via hostPath

## Manifests (apply in order)

1. `1-namespace.yaml` - traefik namespace
2. `2-serviceaccount.yaml` - service account
3. `3-clusterrole.yaml` - RBAC for watching ingress resources
4. `4-clusterrolebinding.yaml` - bind SA to ClusterRole
5. `5-ingressclass.yaml` - IngressClass `traefik`
6. `6-deployment.yaml` - full Deployment with hostNetwork, nodeSelector, tolerations
7. `7-service.yaml` - ClusterIP service (for internal cluster DNS resolution)

## Edge firewall

The edge firewall **moved out of this directory** on 2026-11-19. It now lives
with the rest of the host firewall, at
[`../../bootstrap/host-prep/firewall/`](../../bootstrap/host-prep/firewall/),
and `prepare-host.sh` installs all of it at Layer 0:

| File | Table | Priority | Job |
|---|---|---|---|
| `edgeguard.nft` | `inet edgeguard` | `-200` | Operator SSH allowlist (`ip saddr $ADMIN_SSH_ALLOW_IP tcp dport 22`), plus 80/443, 51820/udp, ICMP, overlay interfaces |
| `edge-guardrail.sh` + `.service` | `inet edge_guardrail` | `-50` | Port allowlist on `eth0`: 22, 80, 443, 51820/udp, ICMP. Accepts `tcp dport 22` from **anywhere** |
| `homelab-fw-edge.sh` + `.service` | iptables `INPUT` | -- | Redundant drops for 10250, 4789/udp, 30000-32767 |

Only `edgeguard` restricts **who** may SSH. `edge_guardrail` restricts only
**which ports** are open, so a healthy `edge-guardrail.service` is not
evidence that SSH is locked down. See
[gate L5-D](../../dr/gates.md#l5----traefik).

## Additional scripts

- `edge-node-placement.sh` - labels and taints the edge node
- `traefik-post-install.sh` - patches security context, strategy, and probes (use only if applying from an older base manifest that lacks these settings)
