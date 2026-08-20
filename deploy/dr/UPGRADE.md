# Cluster upgrade runbook — K3s and Ubuntu

Operator-facing, copy-pasteable, for a cluster that is **healthy and running**. This is the
scheduled-maintenance counterpart to [`RUNBOOK.md`](RUNBOOK.md): same layers, same gates, but
nothing is wiped and nothing is rebuilt. Work one node at a time, top to bottom, and stop at the
first gate that fails.

Phases are numbered `U0`–`U7` so they never collide with the rebuild runbook's `L0`–`L11` layers.
Verification reuses the existing gate IDs from [`gates.md`](gates.md) rather than restating them.

## When to use this

| Situation | What to use |
|---|---|
| Planned K3s version bump | This runbook, all phases. |
| Monthly Ubuntu patching, no K3s change | This runbook — [Routine OS patching](#routine-os-patching-between-upgrades) only. |
| Node stopped answering | [`node-console-recovery.md`](node-console-recovery.md). Something is broken; come back here after. |
| Nodes wiped, rebuilding from cold metal | [`RUNBOOK.md`](RUNBOOK.md). |

## What this changes, and what it does not

**Changes.** The K3s binary and the kubelet/containerd that ship with it, on all four nodes. The
Ubuntu package set and the running kernel.

**Does not change.** Any K3s flag — the install scripts are re-run with byte-identical
`INSTALL_K3S_EXEC`, so node IPs, CIDRs, disabled components and node labels all carry over.
Calico stays where it is: [`install-calico.sh`](../bootstrap/k3s/install-calico.sh) uses
`kubectl create` and is bootstrap-only, so it **cannot** upgrade Calico, and this runbook does not
attempt to. Nor does it cross an Ubuntu LTS boundary — see
[Ubuntu release upgrades](#ubuntu-release-upgrades-2404--2604) for why that is a separate job.

> **The install script rewrites the systemd unit on every run.** All K3s configuration lives in
> `INSTALL_K3S_EXEC` and is baked into the unit at install time — there is no
> `/etc/rancher/k3s/config.yaml` on any node. Any hand-edit made directly on a node is silently
> lost here. If you have one, fold it into the install script in Git *before* starting.

---

## Pre-flight

- [ ] Cluster is green now — `L3-A`, `L7-B`, and `L10-A` all pass before you change anything.
      Upgrading on top of an existing fault turns one problem into two.
- [ ] The target K3s version's release notes have been read, including the intermediate releases
      you are skipping. Check for removed APIs against what the apps actually use.
- [ ] **Calico's support matrix has been checked against the target Kubernetes minor.** The cluster
      runs Calico `v3.31.4` via the Tigera operator. If the target minor is outside its tested
      range, upgrade Calico as a separate, prior maintenance window — with
      `kubectl apply --server-side` against the new operator manifest, not `install-calico.sh`.
- [ ] Backups from `U0` are complete and copied **off the cluster**.
- [ ] You have a console path to every node that does not depend on the cluster: physical
      keyboard/monitor for `ms-1`/`wk-1`/`wk-2`, provider web console for `vm-1`.
- [ ] Roughly two hours, and nobody depending on `*.kakde.eu` during it.

**You do not have to finish in one sitting.** Agents running the old K3s against an upgraded
server is a supported version skew, so it is safe to stop after any node and resume the next day.
Do not stop for *weeks*, though — the skew guarantee is one minor version.

---

## Node order

| # | Node | Role | What breaks while it is down | Notes |
|---|---|---|---|---|
| 1 | `ms-1` | K3s server | API server, `kubectl`, Argo sync. Running pods elsewhere keep running. | Also clears its pending kernel reboot. |
| 2 | `wk-2` | worker | **All of Argo CD, cert-manager, Keycloak, sealed-secrets, Grafana.** SSO breaks for argocd/grafana/synapse/bytebase; no TLS issuance; no SealedSecret decryption. | 19 pods, but **no persistent storage** — the cheapest node to *recover*, not the cheapest outage. |
| 3 | `vm-1` / `ctb-edge-1` | public edge | **Every `*.kakde.eu` host.** Traefik runs only here, on `hostNetwork`. | Also clears its pending kernel reboot. |
| 4 | `wk-1` | worker | Postgres, monitoring TSDBs, bytebase, dblab, synapse + its sandbox. | All 12 local-path PVs live here, plus 22 of the cluster's 61 pods. |

**Why this order.** Server before agents is the K3s rule — a newer API server with older kubelets
is supported, the reverse is not. Then cheapest first: `wk-2` proves the agent procedure costs
almost nothing if it goes wrong. `wk-1` goes last because it is the longest recovery, holds every
byte of persistent state, and has a 96-minute outage precedent (2026-07-18, see
[`NODE-HARDENING.md`](../bootstrap/host-prep/NODE-HARDENING.md)) — it deserves the freshest backup
and an unhurried window with everything else already verified.

Each node follows the same shape:

> cordon → drain → `apt full-upgrade` → K3s install script → reboot → verify → uncordon

One disruption per node, not two. That is the whole reason the OS work and the K3s work share a
window.

### The apt command, and why it carries those flags

Every phase below uses the same invocation. It is longer than `apt-get upgrade` for three
reasons, each of which has bitten someone over SSH:

| Flag | Why |
|---|---|
| `DEBIAN_FRONTEND=noninteractive` | A packaging question with no terminal to answer it hangs the whole run. |
| `NEEDRESTART_MODE=l` | *List* services needing a restart; do not restart them. `needrestart` is installed on `vm-1` and would otherwise bounce Traefik mid-upgrade — on the node that serves all public traffic. The reboot two steps later restarts everything properly anyway. |
| `-o Dpkg::Options::="--force-confold"` | Keep the existing config file when a package ships a new one. Host-prep has customised sysctls, apt config and systemd drop-ins; the default prompt would either stall or silently overwrite them. |

`full-upgrade` rather than `upgrade` because kernel meta-packages pull in new packages, and
`upgrade` refuses to do that.

---

## U0 — Back up before touching anything

**Goal.** Everything needed to put the cluster back exists off-cluster.

### U0.1 The K3s datastore

**This cluster uses SQLite (kine), not etcd.** `k3s etcd-snapshot save` does not work here — it
returns `etcd datastore disabled`. The datastore is a plain file, so back it up by stopping the
server and copying it. `ms-1` is about to be restarted anyway.

```bash
ssh ms-1 'systemctl stop k3s && \
  tar -czf /root/k3s-server-backup-$(date -u +%Y%m%d).tar.gz -C /var/lib/rancher/k3s server && \
  systemctl start k3s && ls -lh /root/k3s-server-backup-*.tar.gz'
# expected: a tarball of roughly 30-60 MB
```

That captures `db/state.db` (the whole cluster state), `node-token` (agents cannot rejoin without
it), and the TLS CA. Pull it to the laptop — a backup that only exists on the node it protects is
not a backup:

```bash
mkdir -p ~/homelab-backups && scp ms-1:/root/k3s-server-backup-*.tar.gz ~/homelab-backups/
```

### U0.2 Application state

All three scripts take the output directory as their **first argument** — they exit with a usage
error without one.

```bash
BK=~/homelab-backups/pre-upgrade-$(date -u +%Y%m%d)
mkdir -p "$BK" && chmod 700 "$BK"

scripts/dr/postgres-backup.sh "$BK"
scripts/dr/sealed-secrets-key-backup.sh "$BK"
```

**Keycloak has four realms, and the script does one realm per run.** `REALM` defaults to `kakde`,
so running it bare backs up neither `synapse` (which every Synapse login depends on) nor
`apps-prod`. Export all of them:

```bash
for r in kakde synapse apps-prod master; do
  REALM="$r" scripts/dr/backup-keycloak-realm.sh "$BK"
done
# expected: each run reports a non-zero client count
# (as of 2026-08-20: kakde 7, synapse 8, apps-prod 9, master 10)
```

**Why all of it.** Postgres is the only copy of the app and Keycloak data. The sealed-secrets key
decrypts every `SealedSecret` in Git — lose it and the manifests are inert. See
[`secret-recovery.md`](secret-recovery.md).

**Check the output, do not just check the exit code.** All three scripts were silently producing
incomplete backups until 2026-08-20:

| Script | Was | Now |
|---|---|---|
| `postgres-backup.sh` | captured only the **first** database — `ssh` drained the `while read` loop's stdin, so keycloak and synapse were never dumped | all 7 databases; a good tarball is ~240K, not ~4K |
| `backup-keycloak-realm.sh` | **zero clients** in every export — it used `GET /admin/realms/{realm}`, which ignores `?exportClients=true` | uses `partial-export`; refuses to keep an export with no clients |
| `sealed-secrets-key-backup.sh` | reported `keys: 0` (miscount only — the file was always correct) | reports the real count, and now fails if the export is genuinely empty |

Sanity-check each result before trusting the window:

```bash
tar -tzf "$BK"/postgres-backup-*.tar.gz | grep -c '\.dump$'   # expected: 7
grep -c 'tls\.key:' "$(ls -t "$BK"/sealed-secrets-master-key-*.yaml | head -1)"  # expected: 5
```

### U0.3 A "before" picture to diff against

```bash
deploy/live-capture/collect-live-state.sh
```

Gitignored and large, but when something looks wrong at `U6` this is what tells you whether it was
already like that.

---

## U1 — Bump the pins in Git first

**Goal.** The repo and the running cluster never disagree about what version is deployed.

Set the new version in all six places, commit, and only then start touching nodes. Because the
pin lives in the scripts, every command below runs them **unmodified** — there is no
`INSTALL_K3S_VERSION=` on any command line to get wrong or forget.

| File | What to change |
|---|---|
| [`../bootstrap/k3s/install-server-ms-1.sh`](../bootstrap/k3s/install-server-ms-1.sh) | `INSTALL_K3S_VERSION` default |
| [`../bootstrap/k3s/install-agent-wk-1.sh`](../bootstrap/k3s/install-agent-wk-1.sh) | same |
| [`../bootstrap/k3s/install-agent-wk-2.sh`](../bootstrap/k3s/install-agent-wk-2.sh) | same |
| [`../bootstrap/k3s/install-agent-vm-1.sh`](../bootstrap/k3s/install-agent-vm-1.sh) | same |
| [`../bootstrap/k3s/README.md`](../bootstrap/k3s/README.md) | the `K3s version:` line |
| [`gates.md`](gates.md) | `L3-A`'s expected-output comment |

```bash
grep -rn "INSTALL_K3S_VERSION" deploy/bootstrap/k3s/
# expected: 4 lines, all the same target version
```

**Do not touch [`SNAPSHOT.md`](SNAPSHOT.md).** It is the frozen historical anchor.
`scripts/dr/verify-snapshot.sh` will report K3s drift from now until `U7` captures a new snapshot —
that is the mechanism working, not a fault.

---

## U2 — ms-1, the K3s server

**Goal.** Control plane on the new version, on the new kernel, with its firewall lockdown intact.

While `ms-1` is down there is no API and no `kubectl`, but pods already running on the other three
nodes keep running — kubelet does not need the API server to keep containers alive.

### U2.1 Cordon and drain

```bash
ssh ms-1 'kubectl cordon ms-1'
ssh ms-1 'kubectl drain ms-1 --ignore-daemonsets --delete-emptydir-data --force --timeout=300s'
```

`ms-1` carries a `NoSchedule` control-plane taint, and the only pods on it are `node-exporter` and
`vector` — both DaemonSet-managed, so `--ignore-daemonsets` skips them and the drain is genuinely a
no-op. Run it anyway: it costs nothing and keeps the procedure identical across all four nodes.

### U2.2 OS packages

```bash
ssh ms-1 'apt-get update && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
  apt-get -y -o Dpkg::Options::="--force-confold" full-upgrade && apt-get -y autoremove'
```

### U2.3 K3s

```bash
ssh ms-1 'bash -s' < deploy/bootstrap/k3s/install-server-ms-1.sh
```

The installer downloads the binary, rewrites the systemd unit from `INSTALL_K3S_EXEC`, and
restarts `k3s` itself. No separate `systemctl restart` is needed.

### U2.4 Reboot

```bash
ssh ms-1 'systemctl reboot'
```

### U2.5 On the way back up — WireGuard first

**Why it's needed.** The API server's only TLS SAN is `172.27.15.12`, its WireGuard address. If
`wg0` does not come up, `kubectl` fails from everywhere including your laptop, and it will look
like K3s is broken when the fault is one layer down.

```bash
ssh ms-1 'wg show wg0 | head -20; ip -4 addr show wg0'
# expected: interface up, address 172.27.15.12/24, three peers with recent handshakes
```

**Gate:** [L2-A, L2-B](gates.md#l2----wireguard-mesh)

### U2.6 Re-arm the firewall lockdown

**Why it's needed.** `k3s-api-lockdown.service` and `k3s-api-lockdown-allow-cluster.service` are
`Type=oneshot RemainAfterExit=yes` and insert their rules at `iptables -I INPUT 1`. They do not
re-run on their own, and a K3s restart rebuilds iptables underneath them — which can leave their
ACCEPT rules ordered *below* K3s's own rules, silently.

```bash
ssh ms-1 'systemctl restart k3s-api-lockdown k3s-api-lockdown-allow-cluster'
ssh ms-1 'iptables -L INPUT -n --line-numbers | head -20'
# expected: the pod (10.42.0.0/16) and service (10.43.0.0/16) ACCEPT rules for ports
# 6443,9345 appear at the TOP of the chain, above any K3s-inserted rules
```

**Gate:** [L0-B, L0-C](gates.md#l0----host-os)

### U2.7 Verify and uncordon

```bash
ssh ms-1 'kubectl get nodes -o wide'
# expected: ms-1 Ready at the new version; the other three still Ready at the old one
ssh ms-1 'kubectl uncordon ms-1'
```

**Gate:** [L3-A, L3-B, L3-C](gates.md#l3----k3s-and-calico)

Let Calico settle before moving on. `calico-node` restarts on the node and typha re-elects; give
it a couple of minutes rather than reacting to the first `0/1`.

---

## U3 — wk-2

**Goal.** Prove the agent procedure on the node that holds no persistent state — so a mistake
costs downtime, never data.

> **This is an SSO and TLS outage, not a quiet one.** `wk-2` runs 19 pods: all seven Argo CD
> components, all three cert-manager pods, **Keycloak**, `sealed-secrets-controller`, and
> Grafana/kube-state-metrics/vmagent. While it is down, logins to argocd, grafana, synapse and
> bytebase fail, no certificate can be issued or renewed, and no `SealedSecret` can be decrypted.
> Public sites that do not require login keep serving.

What it does **not** hold is storage: there are no PersistentVolumes on `wk-2`, which is what makes
it the right node to practise the agent procedure on.

**Argo CD will not move.** Every Argo pod carries `nodeSelector: workload=argocd`, and `wk-2` is the
only node with that label — so during the drain they go **`Pending`** and stay there until `wk-2`
returns. That is expected; do not go hunting for a scheduler fault. Keycloak, cert-manager,
sealed-secrets and Grafana are not pinned and *will* reschedule onto another node, then stay there
after you uncordon (Kubernetes does not rebalance on its own). That part is cosmetic — delete those
pods after `U6` if you want them back on `wk-2`.

```bash
ssh ms-1 'kubectl get nodes -l workload=argocd'
# expected: only wk-2. If you ever need Argo to survive a wk-2 outage, this label
# is the single thing to change.
```

### U3.1 Fetch the join token

The agent install scripts require `K3S_TOKEN`. Read it once and reuse it for `U3`, `U4` and `U5`:

```bash
TOKEN=$(ssh ms-1 'cat /var/lib/rancher/k3s/server/node-token')
```

The token does not change during an upgrade. If you are resuming on a later day, just read it
again.

### U3.2 Cordon, drain, patch, upgrade, reboot

```bash
ssh ms-1 'kubectl cordon wk-2'
ssh ms-1 'kubectl drain wk-2 --ignore-daemonsets --delete-emptydir-data --force --timeout=300s'
ssh wk-2 'apt-get update && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
  apt-get -y -o Dpkg::Options::="--force-confold" full-upgrade && apt-get -y autoremove'
ssh wk-2 "K3S_TOKEN='${TOKEN}' bash -s" < deploy/bootstrap/k3s/install-agent-wk-2.sh
ssh wk-2 'systemctl reboot'
```

Note the double quotes on the install line — `${TOKEN}` must expand on your laptop, and the
script arrives on stdin.

### U3.3 Verify and uncordon

```bash
ssh ms-1 'kubectl get node wk-2 -o wide'
# expected: Ready at the new version
ssh ms-1 'kubectl uncordon wk-2'
```

Argo CD comes back only once `wk-2` is schedulable again (its pods are pinned here). Check that it
actually recovered rather than assuming it did:

```bash
ssh ms-1 'kubectl get pods -n argocd'
# expected: all 7 Running and Ready
ssh ms-1 'kubectl get application -n argocd'
# expected: every Application Synced + Healthy, NOT "Unknown"
```

**If `argocd-repo-server` is stuck `0/1` with `copyutil` in `BackOff` (`/bin/ln: Already exists`),
delete the pod** — the `emptyDir` outlived its containers and the init symlink collides. A fresh
pod gets a clean volume. Until it is healthy, every Application reads `Sync: Unknown` and no GitOps
change can apply. This is not reboot-specific: anything that restarts `k3s-agent` does it, which is
one more reason not to patch a live node outside this runbook:

```bash
ssh ms-1 'kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-repo-server'
```

**Gate:** [L3-A, L3-B](gates.md#l3----k3s-and-calico), [L7-A, L7-B](gates.md#l7----argo-cd)

---

## U4 — vm-1 / ctb-edge-1, the public edge

**Goal.** Edge upgraded and public ingress restored.

> **This is a public outage.** Traefik runs only on this node, on `hostNetwork`. Every
> `*.kakde.eu` host is unreachable from the reboot until Traefik is back. Expect a few minutes.

`vm-1` also has a long-pending kernel reboot, so this is the step that finally activates it.

```bash
ssh ms-1 'kubectl cordon ctb-edge-1'
ssh ms-1 'kubectl drain ctb-edge-1 --ignore-daemonsets --delete-emptydir-data --force --timeout=300s'
ssh vm-1 'apt-get update && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
  apt-get -y -o Dpkg::Options::="--force-confold" full-upgrade && apt-get -y autoremove'
ssh vm-1 "K3S_TOKEN='${TOKEN}' bash -s" < deploy/bootstrap/k3s/install-agent-vm-1.sh
ssh vm-1 'systemctl reboot'
```

The Kubernetes node is named `ctb-edge-1`; the SSH alias is `vm-1`. Cordon/drain take the node
name, `ssh` takes the alias.

### U4.1 Verify and uncordon

```bash
ssh ms-1 'kubectl uncordon ctb-edge-1'
ssh ms-1 'kubectl -n traefik get pods -o wide'
# expected: one Running Traefik pod, on ctb-edge-1
curl -sSI https://kakde.eu | head -3
# expected: HTTP/2 200, valid certificate
```

**Gate:** [L5-A, L5-B, L5-C](gates.md#l5----traefik), [L10-A](gates.md#l10----apps-and-public-reachability)

The edge node's own firewall guardrail (`L5-B`) is worth re-checking specifically — it is host
iptables state, and this node just rebooted onto a new kernel.

---

## U5 — wk-1, the storage node

**Goal.** The last node upgraded, and every stateful workload back.

> **Everything with state lives here.** All 12 local-path PVs — Postgres (80Gi), monitoring
> (2×20Gi), bytebase, and eight dblab volumes — plus 22 of the cluster's 61 pods. Take the time.

### U5.1 About draining this node

The drain **will not move anything**. `local-path` volumes are bound to this machine's disk, so
evicted pods go `Pending` and stay there until `wk-1` comes back. That is expected and is not a
failure.

Drain anyway. Its value here is not rescheduling — it is giving Postgres a graceful `SIGTERM` so
it checkpoints cleanly, instead of being killed mid-write when the kubelet shuts down. That is the
gap called out in [`../bootstrap/host-prep/apt/52unattended-upgrades-reboot`](../bootstrap/host-prep/apt/52unattended-upgrades-reboot):
the unattended-upgrade path does *not* drain, and this runbook is the manual answer to it.

Do **not** reach for `--disable-eviction`. The only PodDisruptionBudgets in the cluster are
`calico-apiserver` and `calico-typha` (`maxUnavailable: 1`), which one-node-at-a-time already
satisfies. If a drain stalls, find out why rather than bypassing the budget.

### U5.2 Run it

```bash
ssh ms-1 'kubectl cordon wk-1'
ssh ms-1 'kubectl drain wk-1 --ignore-daemonsets --delete-emptydir-data --force --timeout=600s'
ssh wk-1 'apt-get update && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
  apt-get -y -o Dpkg::Options::="--force-confold" full-upgrade && apt-get -y autoremove'
ssh wk-1 "K3S_TOKEN='${TOKEN}' bash -s" < deploy/bootstrap/k3s/install-agent-wk-1.sh
ssh wk-1 'systemctl reboot'
```

A longer drain timeout than the other nodes — 22 pods, and Postgres should be allowed to finish.

> **`wk-1` runs a hardware watchdog at `RuntimeWatchdogSec=60`.** A stall longer than 60 seconds
> resets the board. During a normal reboot that is invisible; if the node disappears for longer
> than a few minutes, go to [`node-console-recovery.md`](node-console-recovery.md) rather than
> waiting it out.

### U5.3 Verify and uncordon

```bash
ssh ms-1 'kubectl uncordon wk-1'
ssh ms-1 'kubectl get pods -A --no-headers | grep -vE "Running|Completed"'
# expected: empty, once everything has restarted — give it several minutes
```

**Gate:** [L8-A, L8-B, L8-C](gates.md#l8----postgresql), [L9-A, L9-B](gates.md#l9----keycloak),
[L11-B, L11-D](gates.md#l11----monitoring)

Postgres first — if `L8-B` fails, stop and read its logs before looking at anything downstream.
Keycloak and every app depend on it, so a Postgres fault presents as ten broken things.

---

## U6 — Cluster-wide verification

**Goal.** Prove the whole stack, bottom up, in the order faults propagate.

```bash
ssh ms-1 'kubectl get nodes -o wide'
# expected: 4 rows, all Ready, all at the new version, all with the new kernel
```

Walk the gates in layer order — this is the same bottom-up discipline as the rebuild runbook, and
the reason for it is the same: a Calico fault and a cert fault look identical from the browser.

| Layer | Gates | Checks |
|---|---|---|
| Host | [L0-B, L0-C](gates.md#l0----host-os) | swap off, sysctls, modules, firewall units enabled |
| WireGuard | [L2-A, L2-B](gates.md#l2----wireguard-mesh) | 3 peers each, full-mesh ping |
| K3s + Calico | [L3-A, L3-B, L3-C](gates.md#l3----k3s-and-calico) | nodes Ready, Calico Running, CoreDNS resolves |
| Sealed-Secrets | [L4-A, L4-B](gates.md#l4----sealed-secrets-controller) | controller up, a committed SealedSecret still decrypts |
| Traefik | [L5-A, L5-B, L5-C](gates.md#l5----traefik) | edge-only placement, guardrail, public listener |
| cert-manager | [L6-A, L6-B](gates.md#l6----cert-manager) | ClusterIssuers Ready |
| Argo CD | [L7-A, L7-B, L7-C](gates.md#l7----argo-cd) | all Applications Synced + Healthy |
| PostgreSQL | [L8-A, L8-B, L8-C](gates.md#l8----postgresql) | on wk-1, accepting connections, all DBs present |
| Keycloak | [L9-A, L9-B, L9-C](gates.md#l9----keycloak) | pod ready, OIDC discovery, clients intact |
| Apps | [L10-A, L10-B](gates.md#l10----apps-and-public-reachability) | every public host answers, auth gate still gates |
| Monitoring | [L11-A – L11-E](gates.md#l11----monitoring) | targets up, samples arriving, Grafana OAuth lock |

Then the end-to-end gate at the bottom of [`gates.md`](gates.md).

**Two things specific to an upgrade,** which a rebuild would never surface:

```bash
ssh ms-1 'kubectl get nodes -o wide' | awk '{print $5, $12}'
# expected: kubelet and containerd versions consistent across all four nodes
ssh ms-1 'kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -20'
# expected: nothing about removed or deprecated API versions
```

---

## U7 — Refresh the DR pack

**Goal.** The snapshot describes the cluster you now have, and drift detection goes quiet.

```bash
scripts/dr/snapshot-live-state.sh > deploy/dr/SNAPSHOT-$(date -u +%Y-%m-%d).md
scripts/dr/verify-snapshot.sh
# expected: no K3s version drift reported
```

Then point [`README.md`](README.md)'s pack-contents table at the new snapshot, and commit
everything together with the pin bump from `U1`.

The upgrade is done when four nodes are Ready on the new version, every Argo Application is
Synced + Healthy, `https://kakde.eu` serves a valid certificate, and `verify-snapshot.sh` is quiet.

---

## Rollback, and its limits

**Read this before you start, not after.**

**Agents** downgrade cleanly. Put the old version back in the relevant install script and re-run
it against that node.

**The server does not.** Once a newer API server has written to `state.db`, going back means
restoring the `U0.1` tarball — which **discards every cluster change made since the backup was
taken**. Kubernetes does not support downgrading a minor version in place; the stored object
schemas have already moved.

```bash
# only if you have decided the upgrade must be abandoned
ssh ms-1 'systemctl stop k3s'
ssh ms-1 'tar -xzf /root/k3s-server-backup-<DATE>.tar.gz -C /var/lib/rancher/k3s'
# re-run install-server-ms-1.sh with the OLD version pinned, then the agent scripts likewise
```

In practice, for a homelab, rolling *forward* out of trouble is almost always the better bet —
fix the specific broken thing rather than rewinding the whole cluster. The tarball exists for the
case where the datastore itself is damaged.

---

## Risk register

| Risk | Signal | What to do |
|---|---|---|
| Control plane unreachable after reboot | `kubectl` times out from everywhere | WireGuard first (`U2.5`) — the API's only TLS SAN is the WG IP. If `wg0` is down, no remote `kubectl` exists; use the physical console on `ms-1`. |
| Calico does not settle | `calico-node` not Ready, pods stuck `ContainerCreating` | Give it minutes, not seconds. Then check the Tigera operator logs. Calico's tested range against the new Kubernetes minor is a pre-flight item for exactly this reason. |
| `wk-1` does not come back | Node `NotReady`, no SSH | [`node-console-recovery.md`](node-console-recovery.md). 96-minute precedent on 2026-07-18. The watchdog resets a hang after 60s; it does nothing for power loss. |
| Postgres will not start after `wk-1` returns | `L8-B` fails | Read the pod logs before acting. The `U0.2` dump is the floor, but an unclean shutdown usually replays on its own. |
| Extended public outage | `L10-A` failing after `U4` | Traefik is edge-only; check it is scheduled and that the guardrail (`L5-B`) did not reorder host iptables on reboot. |
| containerd jumps with the K3s minor | Images fail to pull, odd runtime errors | Expected as part of the bump — check the K3s release notes for the containerd version and any runc/cgroup notes. |
| A hand-edited systemd unit vanishes | A flag you relied on is gone | The installer rewrites the unit every run. Fold any local edit into the install script in Git first. |
| **`argocd-repo-server` crash-loops after ANY k3s-agent restart** | Pod `0/1`, init container `copyutil` in `BackOff` with `/bin/ln: Already exists`; every Application goes `Sync: Unknown` with `ComparisonError … connection refused` | The pod's `emptyDir` outlives its containers, so once `copyutil` has run successfully its symlink collides on every later re-run. **Delete the pod** — a new one gets a clean volume. Argo cannot self-heal: without repo-server it renders no manifest, and its pods are pinned to `wk-2` by `workload=argocd` so they cannot move. Triggered twice on 2026-08-20 — once by the `wk-2` reboot at 04:32, then again at 09:23 when a bare `apt upgrade -y` on the live node bounced `k3s-agent` and killed the container (`exitCode 255`, `reason Unknown`). Expect it at `U3`, and check for it after any node patching. |

---

## Why ms-1 and vm-1 do not auto-reboot

`wk-1` (03:30) and `wk-2` (04:30) install
[`52unattended-upgrades-reboot`](../bootstrap/host-prep/apt/52unattended-upgrades-reboot) and
reboot themselves after an unattended upgrade that needs it.

**`ms-1` and `vm-1` deliberately do not,** and this is the considered position rather than an
oversight:

- `vm-1` is the only public entry point. An unattended reboot is an unannounced outage of every
  `*.kakde.eu` host, at 03:30, with nobody watching.
- `ms-1` is the only API server. There is no second control-plane node to carry the cluster.
- Neither reboot would drain first — the unattended path never does.

**The cost is real and should be stated plainly:** it is exactly why both nodes accumulated months
of pending kernel reboots before this upgrade. The countermeasure is a recurring calendar
reminder to run the routine-patching section below — not automation that reboots the control plane
and the public edge unsupervised.

State as of 2026-08-20, which is what this upgrade is about to clear:

| Node | Running kernel | Installed, awaiting reboot |
|---|---|---|
| `ms-1` | 6.17.0-29 | 6.17.0-35 — **pending** |
| `vm-1` | 6.8.0-110 | 6.8.0-111 — **pending** |
| `wk-1` | 7.0.0-28 | 7.0.0-29 — **pending** (its 03:30 unattended reboot has not fired yet) |
| `wk-2` | 7.0.0-29 | none — clean, it auto-rebooted at 04:32 |

`wk-1` being pending shows the auto-reboot is a delay, not an exemption: the package lands, and the
node waits for its window. `ms-1` and `vm-1` wait for *you*.

---

## Routine OS patching between upgrades

For monthly patching with no K3s change. `wk-1` and `wk-2` handle themselves; this is the manual
path for `ms-1` and `vm-1`.

```bash
for n in ms-1 vm-1; do
  echo "== $n"; ssh $n 'apt-get update -qq && apt list --upgradable 2>/dev/null | tail -n +2 | wc -l'
  ssh $n 'test -f /var/run/reboot-required && echo REBOOT-PENDING || echo clean'
done
```

Then, per node, one at a time, never both at once:

```bash
ssh ms-1 'apt-get update && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
  apt-get -y -o Dpkg::Options::="--force-confold" full-upgrade && apt-get -y autoremove'
ssh ms-1 'test -f /var/run/reboot-required && echo "reboot needed"'
```

> **Do not patch a live node with a bare `apt upgrade -y`.** It omits
> `NEEDRESTART_MODE=l`, so `needrestart` bounces services in place — on `wk-2` that restarts
> `k3s-agent`, which kills running containers with `exitCode 255` and leaves
> `argocd-repo-server` crash-looping on the `copyutil` collision described in the risk register.
> That happened on 2026-08-20 at 09:24 and took Argo CD down until the pod was deleted. Use the
> flagged invocation above, and cordon/drain first if the node runs anything you care about.

If a reboot is needed, use the full cordon → drain → reboot → verify → uncordon shape from `U2`
(for `ms-1`) or `U4` (for `vm-1`). A kernel that is installed but not booted is not protecting
anything, so do not let "reboot pending" persist for months.

---

## Ubuntu release upgrades (24.04 → 26.04)

**Not covered by this runbook, and not currently available.** With `Prompt=lts` in
`/etc/update-manager/release-upgrades`, `do-release-upgrade -c` reports no LTS upgrade on offer —
Ubuntu does not open the LTS-to-LTS path until the `.1` point release.

When it does open, treat it as its own project, not an extension of this one. A release upgrade
changes the kernel series, systemd, iptables/nftables backends and the container runtime's
dependencies all at once, and the interaction with Calico VXLAN over WireGuard is precisely where
this cluster is most fragile. Do `vm-1` first as the least stateful node, and expect to revisit
[`../bootstrap/host-prep/README.md`](../bootstrap/host-prep/README.md)'s `rp_filter` caveat.

**See also:** [`RUNBOOK.md`](RUNBOOK.md) · [`gates.md`](gates.md) ·
[`node-console-recovery.md`](node-console-recovery.md) ·
[`../bootstrap/host-prep/NODE-HARDENING.md`](../bootstrap/host-prep/NODE-HARDENING.md)
