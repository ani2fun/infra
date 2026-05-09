# Homelab Kubernetes -- Recovery Pack

This directory contains everything you need to rebuild the homelab Kubernetes
cluster from four bare Ubuntu 24.04 machines and an internet connection.

It is not a tutorial. This is the *executable* counterpart: the manifests,
scripts, and inventory files you actually apply, in the order you actually
apply them. For a disaster-recovery runbook with verification gates, see
`dr/README.md`.

---

## The cluster at a glance

```
                     internet
                        |
                   [ Cloudflare DNS ]
                        |
               84.247.143.66 :80/:443
              +-----------------------+
              |  ctb-edge-1  (vm-1)   |   Contabo cloud VPS
              |  Traefik + firewall   |   WireGuard: 172.27.15.31
              +-----------+-----------+
                          |  WireGuard mesh
           +--------------+---------------+
           |              |               |
    +------+------+ +----+-------+ +-----+------+
    |   ms-1      | |   wk-1     | |   wk-2     |   Home LAN 192.168.15.0/24
    | K3s server  | | PostgreSQL | | Argo CD    |
    | 172.27.15.12| | 172.27.15.11| | 172.27.15.13|
    +-------------+ +------------+ +------------+
```

All inter-node communication travels over a WireGuard mesh so that the three
home machines never need to open ports to the public internet. The only node
with a public IP is the Contabo edge VPS, and even that is locked down to
ports 22, 80, 443, and 51820/udp by an nftables guardrail.

**Design rule:** traffic enters the cluster through one door (Traefik on the
edge node) and reaches internal services over the encrypted mesh. PostgreSQL,
Keycloak's database, and the Kubernetes API are never publicly reachable.

---

## What lives where

| Directory | Purpose |
|-----------|---------|
| `inventory/` | Machine IPs, namespaces, network CIDRs, and a complete workload catalog. Read these first -- they are the single reference for "what number goes where." |
| `dr/` | Disaster-recovery pack: runbook, snapshot, gates, secret-recovery decision tree, and per-component backup procedures. Start here after a total wipe. |
| `bootstrap/host-prep/` | Layer 0: Ubuntu OS prep -- packages, sysctl, kernel modules, netplan templates, SSH hardening, NTP, custom firewall systemd units. Run before WireGuard. |
| `bootstrap/wireguard/` | WireGuard config templates and sysctl tuning. Without the mesh nothing else works. |
| `bootstrap/k3s/` | K3s server and agent install scripts, Calico CNI resources, and node label/taint setup. |
| `platform/traefik/` | The full Traefik ingress stack: namespace, RBAC, Deployment, Service, IngressClass, plus the edge firewall guardrail. |
| `platform/cert-manager/` | Helm install script, Cloudflare DNS-01 secret template, and both ClusterIssuers (staging + production). |
| `platform/argocd/` | Argo CD install and configuration scripts, its Ingress, and the Application manifests that wire up GitOps. |
| `platform/postgresql/` | The complete PostgreSQL StatefulSet stack: namespace, secrets, init scripts, services, NetworkPolicy, and the StatefulSet itself. |
| `apps/keycloak/` | Keycloak identity provider (Deployment, Service, Ingress, secret templates). |
| `apps/whoami/` | A lightweight test app with an OAuth2 Proxy sidecar for verifying the Keycloak OIDC flow end-to-end. |
| `apps/notebook/` | Notebook application (Kustomize base + dev/prod overlays). Deployed via Argo CD in production. |
| `apps/portfolio/` | Portfolio application (same Kustomize pattern). Deployed via Argo CD in production. |
| `live-capture/` | A script that SSHs into every node and dumps the real running state. Useful for auditing drift. |

---

## Rebuild from scratch -- the full sequence

The order matters. Each step depends on the ones above it, and skipping ahead
will leave you debugging symptoms of a missing foundation.

### Layer 0 -- Private network

> *Nothing in this cluster works without WireGuard. If a node can't ping its
> peers over `wg0`, stop here and fix the mesh before touching Kubernetes.*

1. **Bootstrap WireGuard on all four nodes.**
   Copy each node's config from `bootstrap/wireguard/`, replace the key
   placeholders, apply the sysctl file, and bring up `wg-quick@wg0`.
   Verify with `wg show` and cross-node pings.
   See: `bootstrap/wireguard/README.md`

### Layer 1 -- Kubernetes base

2. **Prepare the DNS resolver file on every node.**
   Run `bootstrap/k3s/create-k3s-resolv-conf.sh` so K3s uses a stable
   nameserver instead of the systemd-resolved stub. Without this, CoreDNS
   can enter a forwarding loop.

3. **Install the K3s server on `ms-1`.**
   Run `bootstrap/k3s/install-server-ms-1.sh`. This starts the API server,
   scheduler, and controller-manager. Note: Flannel, the built-in Traefik,
   and ServiceLB are all disabled -- Calico and our own Traefik replace them.

4. **Install Calico on `ms-1`.**
   Run `bootstrap/k3s/install-calico.sh`. This deploys the Tigera operator
   and the Calico custom resources for VXLAN-mode pod networking. Wait until
   `calico-node` pods are Running on ms-1 before joining agents.

5. **Join the worker nodes.**
   Run the three agent install scripts. Each one needs the join token from
   `ms-1` at `/var/lib/rancher/k3s/server/node-token`.

6. **Apply node labels and taints.**
   Run `bootstrap/k3s/apply-node-placement.sh`. This gives each node its
   role label and taints the edge node so only Traefik is scheduled there.

### Layer 2 -- Platform services

7. **Deploy Traefik on the edge node.**
   Apply the numbered manifests in `platform/traefik/` (1 through 7). Then
   copy the firewall script and systemd unit to `vm-1` and enable it. At
   this point `curl http://<edge-ip>` should return a Traefik 404 -- that
   means ingress is working but no routes are configured yet.

8. **Install cert-manager and configure Let's Encrypt.**
   Run `platform/cert-manager/install-cert-manager.sh`, create the
   Cloudflare API token secret, then apply both ClusterIssuers. Certificates
   will be issued automatically when Ingress resources reference them.

9. **Install Argo CD and expose it.**
   Run `platform/argocd/install-argocd.sh`, then `configure-argocd.sh` to
   pin it to `wk-2` and disable internal TLS. Apply `argocd-ingress.yaml`.
   At this point `https://argocd.kakde.eu` should show the login page.

### Layer 3 -- Data services

10. **Deploy PostgreSQL.**
    Label `wk-1` for database placement, label the app namespaces for
    network access, then apply the six numbered manifests in
    `platform/postgresql/`. Verify the pod is Running and you can connect
    from inside the cluster.

11. **Create the Keycloak database.**
    Connect to PostgreSQL and run `platform/postgresql/scripts/create-keycloak-db.sql`
    to create the `keycloak` database and user before deploying Keycloak.

12. **Deploy Keycloak.**
    Apply the manifests in `apps/keycloak/`. Keycloak will connect to
    PostgreSQL on startup, run its schema migrations, and become available
    at `https://keycloak.kakde.eu`.

### Layer 4 -- Applications

13. **Deploy whoami + OAuth2 Proxy** (optional, but useful for verifying the
    full auth chain). Apply the manifests in `apps/whoami/`.

14. **Deploy notebook and portfolio via Argo CD.**
    Apply the Application manifests in `platform/argocd/applications/`.
    Argo CD will sync the Kustomize overlays from this repository and deploy
    both apps into `apps-prod`.

### Verification

Once everything is up, confirm the full stack:

```bash
# Cluster health
kubectl get nodes -o wide
kubectl get pods -A

# Ingress and TLS
kubectl get ingress -A
kubectl get certificate -A

# GitOps
kubectl get application -n argocd

# Public endpoints (from outside the cluster)
curl -sI https://kakde.eu          | head -3
curl -sI https://notebook.kakde.eu | head -3
curl -sI https://keycloak.kakde.eu | head -3
curl -sI https://argocd.kakde.eu   | head -3
curl -sI https://whoami.kakde.eu   | head -3
```

---

## What this pack cannot restore automatically

Some state lives outside Git and must be backed up separately:

| Item | Why it can't be in Git | Recovery method |
|------|----------------------|-----------------|
| PostgreSQL data | Binary database contents | `pg_dump` / `pg_dumpall`, store off-cluster |
| Keycloak realms, clients, users | Stored in the Keycloak DB | Realm export via admin console or `kc.sh export` |
| Cloudflare API token | Real secret | Re-create in Cloudflare dashboard, update the cert-manager Secret |
| WireGuard private keys | Real secrets | Generate fresh with `wg genkey` on each node |
| K3s join token | Generated at server install | Read from `ms-1:/var/lib/rancher/k3s/server/node-token` |
| Let's Encrypt ACME account | Regenerated automatically | cert-manager re-registers on fresh install |

---

## Naming note

The docs and Kubernetes node name call the edge VPS `ctb-edge-1`.
The SSH config calls it `vm-1`. Same machine, same IP (`84.247.143.66`).
Both names appear throughout this pack -- they are interchangeable.
