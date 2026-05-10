# Cluster rebuild runbook

Operator-facing, copy-pasteable rebuild from cold metal. Each layer ends
with a gate ID; if the gate fails, fix it before continuing.

For deeper context on any layer, follow the "See:" link to the existing
per-layer README.

## Pre-flight

Do this on the operator's laptop before touching any node.

- [ ] Local tooling installed: `ssh`, `kubectl`, `helm`, `kubeseal`,
      `jq`, `openssl`, `curl`, `dig`, `nc`.
- [ ] `~/.ssh/config` has aliases for `ms-1`, `wk-1`, `wk-2`, `vm-1`
      reaching `root@`. (For a true cold rebuild, you might temporarily
      use `ubuntu@` over LAN until you've installed the operator's
      authorized_keys and switched to root.)
- [ ] Off-cluster backups reachable:
      - sealed-secrets master-key YAML (`scripts/dr/sealed-secrets-key-backup.sh` output)
      - latest postgres backup tarball (`scripts/dr/postgres-backup.sh` output)
- [ ] Password manager entries unlocked:
      - WireGuard private keys (4 entries, one per node)
      - `postgresql-auth` (4 keys)
      - wk-2 Wi-Fi PSK (only if wk-2 stays on Wi-Fi)
- [ ] Cloudflare admin access; ability to regenerate the API token.
- [ ] Current home IP (`curl ifconfig.me`) for `ADMIN_SSH_ALLOW_IP`.
- [ ] Repo cloned at the snapshot revision:

      ```bash
      git clone https://github.com/ani2fun/infra.git
      cd infra
      git checkout <SHA from deploy/dr/SNAPSHOT.md>
      git rev-parse HEAD   # must match SNAPSHOT.md
      ```

- [ ] Drift check (only if at least one node is still up):

      ```bash
      scripts/dr/verify-snapshot.sh
      ```

      Refresh the snapshot if drift is large; otherwise proceed.

---

## Layer 0 -- Host OS preparation

**Goal.** Each of the four nodes is a clean Ubuntu 24.04.4 LTS install
with the right packages, sysctl, kernel modules, SSH dropin, NTP daemon,
hostname, timezone, and per-node firewall systemd units.

For each node, in this order: `ms-1`, `wk-1`, `wk-2`, `vm-1` (vm-1 last
because it boots into a public-network nftables allowlist that you'll
need to authorize).

Host-prep scripts are maintained out of band (operator notes, not in
this repo). Expected outputs of the prep on each node:

- packages installed (`wireguard`, `nftables`, `chrony`, etc.)
- kernel modules loaded (`br_netfilter`, `vxlan`, `wireguard`)
- sysctl knobs set (`net.ipv4.ip_forward=1`, `net.bridge.bridge-nf-call-iptables=1`)
- hostname / timezone / NTP synced
- `~/.ssh/authorized_keys` for root populated with the operator key
- on `vm-1`: `/etc/edge-allowlist.env` exists (set
  `ADMIN_SSH_ALLOW_IP=<your-home-IP>/32` before applying the
  edge-guardrail in Layer 5)

**Gate:** [L0-A, L0-B, L0-C](gates.md#l0----host-os)

---

## Layer 1 -- Router and DNS

**Goal.** WireGuard UDP traffic can reach each home node from the
internet, and Cloudflare DNS still points at the edge.

### L1.1 Confirm router port-forwards

The home router forwards three UDP ports to the home nodes:

| Public | Target |
|---|---|
| `82.123.119.181:51820/udp` | `wk-1:51820/udp` |
| `82.123.119.181:51821/udp` | `ms-1:51820/udp` |
| `82.123.119.181:51822/udp` | `wk-2:51820/udp` |

Source: [`../inventory/network.yaml`](../inventory/network.yaml).

### L1.2 Confirm Cloudflare records

All A records on `kakde.eu` (per `SNAPSHOT.md`) point to
`84.247.143.66`. If vm-1's public IP changed (new VPS), update them in
the Cloudflare dashboard before continuing.

**Gate:** [L1-A, L1-B](gates.md#l1----router-and-dns)

---

## Layer 2 -- WireGuard mesh

**Goal.** Every node has wg0 up with three peers; pings cross the mesh.

WireGuard keys + per-node `wg0.conf` files are maintained out of band
(operator notes). On rebuild, drop the right `/etc/wireguard/wg0.conf`
on each node, paste the matching private key from the password manager,
then:

```bash
ssh root@<node> 'chmod 600 /etc/wireguard/wg0.conf'
ssh root@<node> 'systemctl enable --now wg-quick@wg0.service'
```

Repeat for all four nodes.

**Gate:** [L2-A, L2-B](gates.md#l2----wireguard-mesh)

---

## Layer 3 -- K3s + Calico

**Goal.** All four nodes joined; Calico CNI healthy; CoreDNS resolves.

K3s install scripts (server, agents, Calico, node placement) are
maintained out of band. Order:

1. Stage a `/etc/resolv.conf` shim on every node so K3s reads upstream
   DNS, not systemd-resolved's stub.
2. Install K3s server on `ms-1`. Capture the join token:
   `cat /var/lib/rancher/k3s/server/node-token`.
3. Install Calico on the cluster.
4. Wait for `calico-node` to be Ready on `ms-1` before joining workers.
5. Join `wk-1`, `wk-2`, `vm-1` (in that order; vm-1 last because it
   needs the edge taint to land).
6. Apply node labels and taints (`kakde.eu/postgresql=true` on `wk-1`,
   `kakde.eu/edge=true` + `NoSchedule` taint on `vm-1`).

**Gate:** [L3-A, L3-B, L3-C](gates.md#l3----k3s-and-calico)

---

## Layer 4 -- Sealed-Secrets controller + key restore

**Goal.** The controller is running with the SAME master key it had at
snapshot time, so every committed `SealedSecret` will decrypt cleanly.

### L4.1 Install the controller

```bash
ssh root@ms-1 \
  'kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.33.1/controller.yaml'
```

### L4.2 Restore the master key

```bash
scripts/dr/sealed-secrets-key-restore.sh /path/to/sealed-secrets-master-key-*.yaml
```

The script scales the controller down, applies the backup, scales it
back up, and prints the active cert fingerprint. Compare against the
fingerprint recorded in `SNAPSHOT.md` (or your password manager).

**See:** [`sealed-secrets-key-backup.md`](sealed-secrets-key-backup.md)

**Gate:** [L4-A, L4-B](gates.md#l4----sealed-secrets-controller)
(L4-B requires Argo CD to apply the SealedSecret -- defer until L7 if you
prefer; the gate works at any later point.)

---

## Layer 5 -- Traefik + edge guardrail

**Goal.** Public 80/443 reach Traefik; everything else on the public NIC
is blocked by the nftables allowlist.

### L5.1 Edge node placement

```bash
ssh root@ms-1 'bash -s' < deploy/platform/traefik/edge-node-placement.sh
```

### L5.2 Apply Traefik manifests

```bash
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/traefik/1-namespace.yaml
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/traefik/2-serviceaccount.yaml
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/traefik/3-clusterrole.yaml
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/traefik/4-clusterrolebinding.yaml
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/traefik/5-ingressclass.yaml
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/traefik/6-deployment.yaml
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/traefik/7-service.yaml
```

### L5.3 Install the edge firewall on vm-1

Confirm `/etc/edge-allowlist.env` has the right IP from L0, then:

```bash
scp deploy/platform/traefik/edge-guardrail.sh root@vm-1:/usr/local/sbin/
scp deploy/platform/traefik/edge-guardrail.service root@vm-1:/etc/systemd/system/
ssh root@vm-1 'systemctl daemon-reload && systemctl enable --now edge-guardrail.service'
```

After this enables, your laptop's SSH connection to vm-1 will only work
if your home IP matches the allowlist. **Test from a second terminal
before closing the first.**

**See:** [`../platform/traefik/README.md`](../platform/traefik/README.md)

**Gate:** [L5-A, L5-B, L5-C](gates.md#l5----traefik)

---

## Layer 6 -- cert-manager + ClusterIssuers

**Goal.** TLS certs auto-issue on every Ingress.

### L6.1 Install cert-manager

```bash
ssh root@ms-1 'bash -s' < deploy/platform/cert-manager/install-cert-manager.sh
```

The script pins `--version v1.19.1`. Override with `CERT_MANAGER_VERSION`
env var if the snapshot has been refreshed to a newer pin.

### L6.2 Apply the Cloudflare token

Regenerate the token at Cloudflare per
[`secret-recovery.md#cloudflare-api-token`](secret-recovery.md#cloudflare-api-token):

```bash
ssh root@ms-1 'kubectl -n cert-manager create secret generic cloudflare-api-token --from-literal=api-token=<<NEW_TOKEN>>'
```

### L6.3 Apply ClusterIssuers

```bash
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/cert-manager/clusterissuer-prod.yaml
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/cert-manager/clusterissuer-staging.yaml
```

**See:** [`../platform/cert-manager/README.md`](../platform/cert-manager/README.md)

**Gate:** [L6-A, L6-B](gates.md#l6----cert-manager)

---

## Layer 7 -- Argo CD + Applications

**Goal.** Argo CD running, all three apps Synced + Healthy.

### L7.1 Install Argo CD

```bash
ssh root@ms-1 'bash -s' < deploy/platform/argocd/install-argocd.sh
ssh root@ms-1 'bash -s' < deploy/platform/argocd/configure-argocd.sh
```

### L7.2 Apply the Ingress

```bash
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/argocd/argocd-ingress.yaml
```

### L7.3 Apply the three Applications

```bash
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/argocd/applications/codefolio.yaml
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/argocd/applications/dsa-tracker.yaml
ssh root@ms-1 'kubectl apply -f -' < deploy/platform/argocd/applications/piston.yaml
```

Argo CD will sync the three overlays from `deploy/apps/<app>/overlays/prod/`
in this repo. Each app's `SealedSecret` (where applicable) decrypts via the
controller key restored in L4.

**See:** [`../platform/argocd/README.md`](../platform/argocd/README.md)

**Gate:** [L7-A, L7-B, L7-C](gates.md#l7----argo-cd)

Note that the apps Argo CD just synced will be in a partial state until
L8 brings up postgres -- backends that need a DB connection will be
CrashLoopBackOff. That is expected.

---

## Layer 8 -- PostgreSQL + DB restore

**Goal.** PostgreSQL running on wk-1 with all known databases (`appdb`,
`dsa_tracker`, etc.) restored from backup.

### L8.1 Apply the postgres manifests

```bash
ssh root@ms-1 'bash -s' < deploy/platform/postgresql/label-access.sh
```

Edit `deploy/platform/postgresql/2-secret.yaml` to substitute the
plaintext from `secret-recovery.md`, then:

```bash
for f in deploy/platform/postgresql/{1..6}-*.yaml; do
  ssh root@ms-1 "kubectl apply -f -" < "$f"
done
```

Wait for `postgresql-0` to be Ready.

### L8.2 Restore the latest dump

```bash
scripts/dr/postgres-restore.sh /path/to/postgres-backup-*.tar.gz
```

The script restores globals first, then per-database dumps, and prints a
row-count comparison against the inventory captured at backup time.

**See:** [`../platform/postgresql/README.md`](../platform/postgresql/README.md)

**Gate:** [L8-A, L8-B, L8-C](gates.md#l8----postgresql)

---

## Final verification

End-to-end public reachability:

```bash
for h in kakde.eu dev.codefolio.kakde.eu \
         argocd.kakde.eu \
         dsa-tracker.kakde.eu; do
  printf "%-32s " "$h"
  curl -sI "https://$h/" -o /dev/null -w "%{http_code}\n" || echo "FAIL"
done
```

Capture a fresh snapshot for the new operational era:

```bash
scripts/dr/snapshot-live-state.sh > deploy/dr/SNAPSHOT-$(date -u +%Y-%m-%d).md
git add deploy/dr/SNAPSHOT-*.md
git commit -m "Refresh DR snapshot after rebuild"
```

Update `deploy/dr/README.md`'s table to point operators at the new
snapshot.

Take a fresh sealed-secrets master-key backup (the controller was
rebuilt during L4, so its key didn't change -- but verify you still
have a recoverable copy):

```bash
scripts/dr/sealed-secrets-key-backup.sh ~/secure-dr-backups/
```

Take a fresh postgres backup:

```bash
scripts/dr/postgres-backup.sh ~/secure-dr-backups/
```

The cluster is back.
