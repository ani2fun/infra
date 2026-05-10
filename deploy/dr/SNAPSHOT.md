# Cluster snapshot -- 2026-05-09

Frozen reference of "what current state means" on the day this DR pack was
authored. **Never edit this file in place.** Future captures land as new
files (`SNAPSHOT-YYYY-MM-DD.md`); this one stays as the historical anchor.

To regenerate the data below, run `scripts/dr/snapshot-live-state.sh`.
To check live drift against this file, run `scripts/dr/verify-snapshot.sh`.

---

## Capture metadata

| Field | Value |
|---|---|
| Snapshot date (UTC) | 2026-05-09 |
| Repo Git revision | `28322934eccb799bb7281bff6b1837b8f8668c96` |
| Capture method | live SSH + `kubectl` from `ms-1` |
| Cluster age at capture | 67 days (cluster created 2026-03-02) |

Verify the repo SHA on rebuild day:

```bash
git rev-parse HEAD
# expected: 28322934eccb799bb7281bff6b1837b8f8668c96
```

---

## Nodes

| Hostname | Role | LAN IP | WireGuard IP | Public IP | OS | Kernel |
|---|---|---|---|---|---|---|
| ms-1 | K3s server | 192.168.15.2 | 172.27.15.12 | -- | Ubuntu 24.04.4 LTS | 6.17.0-20-generic |
| wk-1 | worker (postgres) | 192.168.15.3 | 172.27.15.11 | -- | Ubuntu 24.04.4 LTS | 6.17.0-23-generic |
| wk-2 | worker (argocd) | 192.168.15.4 | 172.27.15.13 | -- | Ubuntu 24.04.4 LTS | 6.17.0-20-generic |
| ctb-edge-1 (vm-1) | edge worker (Traefik) | -- | 172.27.15.31 | 84.247.143.66 | Ubuntu 24.04.4 LTS | 6.8.0-110-generic |

Notes:
- Home nodes use the HWE kernel (`linux-generic-hwe-24.04`); edge uses
  `linux-virtual` from the Contabo image.
- wk-2 connects via Wi-Fi (`wlo1` / SSID `Macaw-Tucan`); ms-1 and wk-1
  are wired Ethernet. See `bootstrap/host-prep/netplan/wk-2.yaml.example`.
- ctb-edge-1 is the Kubernetes node name; vm-1 is the SSH alias. Same host.

## Network

| Range | Purpose |
|---|---|
| `192.168.15.0/24` | Home LAN (DHCP from local router) |
| `172.27.15.0/24` | WireGuard mesh on `wg0` |
| `10.42.0.0/16` | Pod CIDR (Calico VXLAN, MTU 1370) |
| `10.43.0.0/16` | Service CIDR |
| `84.247.143.66/20` | Public IPv4 on `ctb-edge-1` (Contabo) |
| `2a02:c207:2311:7393::1/64` | Public IPv6 on `ctb-edge-1` |

WireGuard listen port: `51820/udp` on every node. The home router forwards
the corresponding port back to each home node so the edge can reach them.

## Public DNS records (Cloudflare zone `kakde.eu`)

All A records resolve to `84.247.143.66`:

- `kakde.eu`
- `dev.codefolio.kakde.eu`
- `argocd.kakde.eu`
- `keycloak.kakde.eu`
- `whoami.kakde.eu`
- `whoami-auth.kakde.eu`
- `dsa-tracker.kakde.eu`

## Host-level facts (per node)

| Fact | ms-1 | wk-1 | wk-2 | ctb-edge-1 |
|---|---|---|---|---|
| swap | OFF | OFF | OFF | OFF |
| `net.ipv4.ip_forward` | 1 | 1 | 1 | 1 |
| `net.ipv4.conf.all.rp_filter` | 2 | 2 | 2 | 2 |
| `net.ipv4.conf.wg0.rp_filter` | 0 | 0 | 0 | 0 |
| `net.bridge.bridge-nf-call-iptables` | 1 | 1 | 1 | 1 |
| modules: `br_netfilter` | loaded | loaded | loaded | loaded |
| modules: `vxlan` | loaded | loaded | loaded | loaded |
| modules: `overlay` | loaded | loaded | loaded | -- |
| NTP daemon | systemd-timesyncd | systemd-timesyncd | chrony | systemd-timesyncd |
| Timezone | Europe/Paris | Europe/Paris | Europe/Paris | Europe/Berlin |
| SSH `PermitRootLogin` | prohibit-password | prohibit-password | prohibit-password | prohibit-password (cloud image) |
| SSH `PasswordAuthentication` | no | no | no | no |

Custom firewall systemd units (per node):

| Service | ms-1 | wk-1 | wk-2 | ctb-edge-1 |
|---|---|---|---|---|
| `homelab-fw-ms1.service` | active | -- | -- | -- |
| `k3s-api-lockdown.service` | active | -- | -- | -- |
| `k3s-api-lockdown-allow-cluster.service` | active | -- | -- | -- |
| `homelab-fw-edge.service` | -- | -- | -- | active |
| `edge-guardrail.service` | -- | -- | -- | active |

---

## Kubernetes platform versions

| Component | Version | Helm chart | Image digest source |
|---|---|---|---|
| K3s | `v1.35.1+k3s1` | -- | binary install |
| containerd | `v2.1.5-k3s1` | -- | bundled with K3s |
| Tigera operator | `v1.40.7` | -- | `quay.io/tigera/operator@sha256:53260704fc6e638633b243729411222e01e1898647352a6e1a09cc046887973a` |
| Calico (CNI) | `v3.31.4` | -- | see image table |
| Sealed Secrets controller | `0.33.1` | manifest install | `docker.io/bitnami/sealed-secrets-controller@sha256:e7fad65c2d2f47e48d9ca17408ed56961bfa6a6dd74ccd4a1a214664156534bc` |
| cert-manager | `v1.19.1` | `cert-manager-v1.19.1` | see image table |
| Traefik | `v2.11` | manifest install | `docker.io/library/traefik@sha256:ad45e9eb6b148c6bc8d5dbe309412758d48d6027a37591057dc9d10fbfbe8ce5` |
| Argo CD | `v3.3.3` | helm | `quay.io/argoproj/argocd@sha256:8b9a0993937850c1ee6e2ada47a2be8259d512e959ae58afa39936658f7b52e7` |
| PostgreSQL | `17.9` | manifest StatefulSet | `docker.io/library/postgres@sha256:2cd82735a36356842d5eb1ef80db3ae8f1154172f0f653db48fde079b2a0b7f7` |
| Keycloak | `26.5.5` | manifest Deployment | `quay.io/keycloak/keycloak@sha256:a7b0cb7a43a1235a61872883414d3f1d9a3ceac9df6e5907bd12202778a6265c` |
| oauth2-proxy (whoami-auth) | `v7.14.3` | manifest Deployment | (live capture pending PR 8) |
| CoreDNS | `1.14.1` | bundled | `docker.io/rancher/mirrored-coredns-coredns@sha256:82b57287b29beb757c740dbbe68f2d4723da94715b563fffad5c13438b71b14a` |
| local-path-provisioner | `v0.0.34` | bundled | `docker.io/rancher/local-path-provisioner@sha256:6ff68ebe98bc623b45ad22c28be84f8a08214982710f3247d5862e9bccce73ef` |
| metrics-server | `v0.8.1` | bundled | `docker.io/rancher/mirrored-metrics-server@sha256:b2d2efaf5ac3b366ed0f839d2412a2c4279d4fc2a2a733f12c52133faed36c41` |

---

## Application images and digests

Captured from running pods. The image **digest** is the source of truth on
restore; tags can drift.

### Argo CD-managed apps

| App | Image | Digest |
|---|---|---|
| codefolio (prod) | `ghcr.io/ani2fun/codefolio:<sha>` | `<captured-on-next-snapshot>` |
| codefolio-redis | `docker.io/library/redis:7-alpine` | `<captured-on-next-snapshot>` |
| codefolio-mongo | `docker.io/library/mongo:7` | `<captured-on-next-snapshot>` |
| dsa-tracker-backend | `ghcr.io/ani2fun/dsa-tracker-backend:a62470690a49f10432b0e15814d11823ac1cfdbe` | `sha256:23092d4edc044ab3d0fe51fbd420292aae6fe8dbe80b0879e6d506f9e820a07b` |
| dsa-tracker-frontend | `ghcr.io/ani2fun/dsa-tracker-frontend:1fcdfe9051fdfc4224a8b4bb3b553161e1a4f593` | `sha256:109b5935d94ea2fa5ee26f4f5cb1142fae3aa80aa7e2628d46f0eef8b64d56ec` |
| piston | `ghcr.io/engineer-man/piston:latest` | `sha256:2f66b7456189c4d713aa986d98eccd0b6ee16d26c7ec5f21b30e942756fd127a` |

### Manually applied apps

| App | Image | Digest |
|---|---|---|
| keycloak | `quay.io/keycloak/keycloak:26.5.5` | `sha256:a7b0cb7a43a1235a61872883414d3f1d9a3ceac9df6e5907bd12202778a6265c` |
| postgresql | `docker.io/library/postgres:17.9` | `sha256:2cd82735a36356842d5eb1ef80db3ae8f1154172f0f653db48fde079b2a0b7f7` |
| whoami | `docker.io/traefik/whoami:latest` | `sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab` |

`whoami-oauth2-proxy` (referenced in older inventory copies) is **not
currently deployed**. The manifests in `k8s-cluster/apps/whoami/` are
templates; deploy via the steps in that directory's README if/when
`whoami-auth.kakde.eu` is needed.

---

## Argo CD Application revisions

| Application | Source path | Tracked branch | Synced commit | Sync policy |
|---|---|---|---|---|
| `codefolio` | `deploy/codefolio/overlays/prod` | `main` | `<captured-on-next-snapshot>` | auto, prune, selfHeal |
| `piston` | `deploy/piston/overlays/prod` | `main` | `b2e353931c637ecc391cf60e3d8be2070bed4f69` | auto, prune, selfHeal |
| `dsa-tracker` | `deploy/dsa-tracker/overlays/prod` | `main` | `b2e353931c637ecc391cf60e3d8be2070bed4f69` | auto, prune, selfHeal |

All three Applications point at `https://github.com/ani2fun/infra.git`.

---

## Persistent volumes

| Bound to | Size | StorageClass | Storage path on host |
|---|---|---|---|
| `databases-prod/data-postgresql-0` | 80 Gi | `local-path` | `/var/lib/rancher/k3s/storage/...` on `wk-1` |
| `apps-prod/piston-packages` | 10 Gi | `local-path` | `/var/lib/rancher/k3s/storage/...` (current scheduling node) |

The `local-path` provisioner uses the host filesystem directly. PVC data is
**not** replicated; loss of `wk-1`'s root disk = loss of postgres data.
See `dr/RUNBOOK.md` Layer 8 and `scripts/dr/postgres-backup.sh`.

---

## ClusterIssuers

| Name | ACME server | Status |
|---|---|---|
| `letsencrypt-prod-dns01` | `https://acme-v02.api.letsencrypt.org/directory` | Ready |
| `letsencrypt-staging-dns01` | `https://acme-staging-v02.api.letsencrypt.org/directory` | Ready |

Both use the Cloudflare DNS-01 solver. Cloudflare API token is in the
`cert-manager/cloudflare-api-token` Secret with key `api-token`. See
`dr/secret-recovery.md` for restoration steps.

---

## Off-cluster backups expected (operator must maintain)

| Item | Where it lives off-cluster | Last verified | Restore script |
|---|---|---|---|
| Sealed-Secrets master key | password manager + encrypted USB | (operator records) | `scripts/dr/sealed-secrets-key-restore.sh` |
| PostgreSQL dump (`pg_dumpall` + per-DB `pg_dump`) | (operator's chosen destination) | (operator records) | `scripts/dr/postgres-restore.sh` |
| Keycloak realm export (`kakde-realm-*.json`) | password manager / encrypted USB | (operator records) | manual `kc.sh import` per `dr/keycloak-realm-export.md` |
| WireGuard private keys per node | password manager (4 entries) | (operator records) | manually copy to `/etc/wireguard/wg0.key` |
| wk-2 Wi-Fi PSK | password manager | (operator records) | netplan template fill-in |
| Cloudflare API token | Cloudflare dashboard (regenerate as needed) | (operator records) | `kubectl create secret generic cloudflare-api-token` |
| `ADMIN_SSH_ALLOW_IP` (current home IP) | record in password manager | (operator records) | fill into `bootstrap/host-prep/firewall/edge-allowlist.env` |

---

## How to refresh this snapshot

This file is **frozen**. Do not edit it. To capture a newer state:

```bash
scripts/dr/snapshot-live-state.sh > k8s-cluster/dr/SNAPSHOT-$(date -u +%Y-%m-%d).md
```

Review the new file, then update `dr/README.md` to point operators at the
newest snapshot. Keep older snapshots so post-mortems can compare.
