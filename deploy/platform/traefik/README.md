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

After Traefik is running, apply the edge firewall guardrail on `vm-1`:

```bash
scp edge-guardrail.sh vm-1:/usr/local/sbin/edge-guardrail.sh
scp edge-guardrail.service vm-1:/etc/systemd/system/edge-guardrail.service
ssh vm-1 'chmod +x /usr/local/sbin/edge-guardrail.sh && systemctl daemon-reload && systemctl enable --now edge-guardrail.service'
```

The guardrail allows only SSH (22), HTTP (80), HTTPS (443), and WireGuard (51820/udp) on the public interface. All other inbound traffic on `eth0` is dropped.

## Additional scripts

- `edge-node-placement.sh` - labels and taints the edge node
- `traefik-post-install.sh` - patches security context, strategy, and probes (use only if applying from an older base manifest that lacks these settings)
