# Ubuntu LTS release upgrade — 24.04 → 26.04

Operator-facing, for a cluster that is **healthy and running**. This is a different job from
[`UPGRADE.md`](UPGRADE.md), not a phase of it. That runbook moves K3s and patches Ubuntu inside
one LTS series; this one crosses the series boundary, which replaces systemd, glibc, the kernel
series, the netfilter tooling and the container runtime's dependencies in a single transaction.

Phases are lettered `R0`–`R8` so they never collide with `UPGRADE.md`'s `U0`–`U7` or
[`RUNBOOK.md`](RUNBOOK.md)'s `L0`–`L11`. Verification reuses the gate IDs from
[`gates.md`](gates.md).

**K3s does not move here.** The target is the same `v1.36.6+k3s1` the cluster already runs, on a
new OS underneath it. Changing both at once would leave you unable to say which one broke.

## Status

| Fact | Value | Checked |
|---|---|---|
| Installed | Ubuntu 24.04.5 LTS, all four nodes | 2026-11-19 |
| Available | Ubuntu 26.04.1 LTS | 2026-11-19 |
| Upgrade path | **Open.** `do-release-upgrade -c` offers it on all four nodes | 2026-11-19 |
| `Prompt=` | `lts` in `/etc/update-manager/release-upgrades`, all four | 2026-11-19 |
| Kernel now | `7.0.0-43` on `ms-1`/`wk-1`/`wk-2`, `6.8.0-149` on `vm-1` | 2026-11-19 |

24.04 LTS has standard support until **April 2029**. Nothing forces this upgrade. Do it because
you want the newer stack, not because the current one is expiring — and do it when you have a
free weekend, not an evening.

`vm-1` is the only node still on the 6.8 GA kernel; the three home nodes already run 7.0 via the
HWE stack. So `vm-1` takes the larger kernel jump *and* is the node you cannot physically touch.

---

## Pre-flight

- [ ] Cluster is green now — `L3-A`, `L7-B` and `L10-A` all pass. Do not upgrade on top of a fault.
- [ ] `U0` backups are complete and copied **off the cluster**: the K3s datastore tarball, all
      seven Postgres databases, the Keycloak realm exports, the sealed-secrets master key.
      Re-read [`UPGRADE.md`](UPGRADE.md#u0--back-up-before-touching-anything); do not improvise this.
- [ ] A `collect-live-state.sh` run is in hand as the "before" picture.
- [ ] kured is paused. A release upgrade leaves `/var/run/reboot-required` set for hours.
- [ ] Console access proven **before** you start, not looked up afterwards: physical
      keyboard/monitor for `ms-1`/`wk-1`/`wk-2`, and a Contabo VNC session you have actually
      logged into for `vm-1`. See [`node-console-recovery.md`](node-console-recovery.md).
- [ ] You accept that there is no rollback. See [Rollback, and why there is none](#rollback-and-why-there-is-none).

### Check the desktop stack first

`ms-1` and `wk-2` were installed from the Ubuntu **desktop** image; `wk-1` and `vm-1` were not.
Ubuntu 26.04 drops X11/Xorg for the default GNOME session, so that stack is the part of the
transition most likely to produce conffile prompts and obsolete-package lists.

```bash
for n in ms-1 wk-1 wk-2 vm-1; do
  echo -n "$n "; ssh $n 'dpkg -l | grep -cE "^ii +(ubuntu-desktop|gnome-shell|xserver-xorg)"'
done
# as of 2026-11-19: ms-1 23, wk-1 0, wk-2 23, vm-1 0
```

That `ms-1` — the control plane — is one of the two carrying it is the awkward part. A headless
node does not need the stack at all. Removing it is a legitimate thing to do *before* `R1`, in its
own change with its own reboot, and it shrinks the release upgrade considerably. It is not part of
this runbook, and it must never share a window with the release upgrade.

---

## Node order

Different from `UPGRADE.md`, and deliberately so.

| # | Node | Why here |
|---|---|---|
| 1 | `wk-2` | Stateless **and** physically reachable. If 26.04 breaks the boot, you walk over with a keyboard. Proves the procedure at the lowest cost. |
| 2 | `vm-1` / `ctb-edge-1` | Stateless, but remote. Second, so the procedure is already known-good before you try it on a node whose only recovery is VNC. |
| 3 | `ms-1` | Control plane. Losing it costs the cluster's SQLite state — recoverable from the `U0` tarball, but a bad afternoon. |
| 4 | `wk-1` | All 12 local-path PVs and 22 of the 61 pods. Longest recovery, freshest backup, unhurried window. |

**Why not `vm-1` first.** An earlier note in `UPGRADE.md` suggested leading with `vm-1` because it
is the least stateful node. Statelessness is the wrong axis here. The failure this runbook is
built around is *the node does not come back*, and what decides how bad that is, is whether you
can reach the console. `wk-2` is equally stateless and sits in the same room as you.

**The K3s server-before-agent rule does not apply.** That rule exists because of kubelet/API
version skew. K3s does not change version here, so order is governed purely by blast radius.

Each node follows the same shape:

> cordon → drain → stop K3s → open the recovery path → `do-release-upgrade` → reboot → re-assert host-prep → verify → uncordon

---

## R0 — Open the recovery path on `vm-1` before anything else

**Goal.** Make sure a half-finished upgrade cannot lock you out of the edge node.

`do-release-upgrade` starts a **second sshd on port 1022** as a fallback, so a dropped primary
sshd does not strand you. On `vm-1` that fallback is useless as shipped: two nftables tables
filter `eth0`, both with `policy drop`, and neither permits 1022.

| Table | Priority | Source on the node | Source in the repo | Loaded by |
|---|---|---|---|---|
| `inet edgeguard` | `-200` | `/etc/nftables.d/edgeguard.nft` | `deploy/bootstrap/host-prep/firewall/edgeguard.nft` | `nftables.service` |
| `inet edge_guardrail` | `-50` | `/usr/local/sbin/edge-guardrail.sh` | `deploy/bootstrap/host-prep/firewall/edge-guardrail.sh` | `edge-guardrail.service` |

`edgeguard` accepts SSH only from the operator's home IP; `edge_guardrail` accepts `tcp dport 22`
on `eth0` from anywhere. Port 1022 is dropped by both. `ufw` is inactive and the `iptables`
`INPUT` policy is `ACCEPT`, so these two tables are the whole story.

> **Drift — resolved 2026-11-19.** Both tables are now under version control in
> `deploy/bootstrap/host-prep/firewall/`, and `prepare-host.sh` installs them on `ctb-edge-1`.
> The admin IP is no longer hardcoded: `edgeguard.nft` references
> `$ADMIN_SSH_ALLOW_IP`, which `prepare-host.sh` renders into
> `/etc/nftables.d/00-edge-allowlist.nft` from `/etc/edge-allowlist.env`. That generated file is
> the only place the real IP lives on disk, and it is never committed.
>
> `edgeguard.nft` in the repo carries one intentional addition over the file that was live on
> `vm-1`: a `table inet edgeguard` / `delete table inet edgeguard` prologue, so
> `nft -f /etc/nftables.conf` is idempotent instead of appending a duplicate copy of every rule.

**R0.1 Diff the live tables against the repo** before you start, so you know the rebuild path and
the running node still agree, and so you have a baseline to re-diff after the upgrade:

```bash
ssh vm-1 'cat /etc/nftables.d/edgeguard.nft' > /tmp/edgeguard.nft.live
ssh vm-1 'cat /usr/local/sbin/edge-guardrail.sh' > /tmp/edge-guardrail.sh.live

diff <(sed "s|\$ADMIN_SSH_ALLOW_IP|$(ssh vm-1 'awk -F= "/ADMIN_SSH_ALLOW_IP/{print \$2}" /etc/edge-allowlist.env')|" \
        deploy/bootstrap/host-prep/firewall/edgeguard.nft) /tmp/edgeguard.nft.live
diff deploy/bootstrap/host-prep/firewall/edge-guardrail.sh /tmp/edge-guardrail.sh.live
```

Expect only the idempotency prologue and comment differences noted above. Anything else is new
drift: fold it back into the repo files before you upgrade, not after.

**R0.2 Temporarily admit 1022**, immediately before the `vm-1` phase and from your own IP only:

```bash
ADMIN_IP=$(curl -fsS https://ifconfig.me)
ssh vm-1 "nft add rule inet edgeguard input ip saddr ${ADMIN_IP}/32 tcp dport 1022 accept; \
          nft add rule inet edge_guardrail input iifname eth0 ip saddr ${ADMIN_IP}/32 tcp dport 1022 accept"
# expected: no output. Both are runtime-only — neither file on disk is touched.
```

Because they are runtime-only, the reboot in `R4` removes them by itself. Confirm afterwards:

```bash
ssh vm-1 'nft list ruleset | grep -c 1022'
# expected: 0
```

**Gate `R0-A`:** `nft list ruleset | grep 1022` shows exactly two rules before the upgrade, and
zero after the reboot.

**R0.3 Run the upgrade inside `tmux`**, on every node, not just `vm-1`. A release upgrade takes
30–60 minutes and a dropped SSH session kills a bare `do-release-upgrade` mid-transaction, which
is the single most likely way to brick a node here.

```bash
ssh -t vm-1 'tmux new -As relupg'
# then run do-release-upgrade inside it; reattach after any disconnect with the same command
```

---

## R1 — Fully patch 24.04 first

`do-release-upgrade` refuses to start against a system with pending work, and a partial upgrade
crossing the series boundary is far harder to reason about.

```bash
ssh <node> 'apt-get update && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
  apt-get -y -o Dpkg::Options::="--force-confold" full-upgrade && apt-get -y autoremove'
ssh <node> 'apt list --upgradable 2>/dev/null | tail -n +2 | wc -l'
```

A non-zero count is usually **phased updates**, not a fault. Confirm before worrying:

```bash
ssh <node> 'apt-mark showhold; apt-cache policy <pkg> | grep phased'
# expected: no holds; "(phased NN%)" against the candidate version
```

Phased packages are safe to leave — the release upgrade supersedes them. A package that is
genuinely **held** is not; resolve it before going on.

---

## R2 — Inventory what host-prep owns

`do-release-upgrade` asks about modified conffiles interactively and does **not** honour the
`--force-confold` default that `UPGRADE.md` relies on. Every file below is a local customisation
that a wrong keypress silently reverts. Record the hashes now so `R5` can prove nothing moved.

```bash
ssh <node> 'md5sum /etc/sysctl.d/*.conf /etc/modules-load.d/*.conf \
  /etc/ssh/sshd_config.d/*.conf /etc/apt/apt.conf.d/52unattended-upgrades-reboot \
  /etc/systemd/system/oom-resilience-reassert.* 2>/dev/null'
```

| Area | Files | What breaks if reverted |
|---|---|---|
| Sysctl | `99-k3s-calico.conf`, `99-wireguard.conf`, `10-panic.conf`, `10-map-count.conf`, `20-oom-resilience.conf`, `21-sysrq-console.conf`, `99-cloudimg-ipv6.conf` | `rp_filter` on `wg0`, OOM self-heal, SysRq console recovery |
| Modules | `k3s-calico.conf`, `k8s.conf`, `watchdog.conf` | VXLAN and `br_netfilter` missing at boot |
| SSH | `99-root-login.conf`, `60-cloudimg-settings.conf` (edge) | **Root login refused — you lose the node** |
| Firewall | `homelab-fw-*.service`, `k3s-api-lockdown*`, `nftables.service` + `edgeguard.nft`, `edge-guardrail.service` | API server exposed, or edge SSH allowlist gone (see gate `L5-D`) |
| OOM | `oom-resilience-reassert.service` / `.timer` | `vm.panic_on_oom` drifts back to 0 |

> **`99-root-login.conf` is the one that locks you out.** When the upgrade offers to replace
> `/etc/ssh/sshd_config`, **keep the local version**. If you take the maintainer's, confirm the
> `Include /etc/ssh/sshd_config.d/*.conf` line survives before you let the session close.

### The rp_filter caveat still applies

`99-wireguard.conf` sets `net.ipv4.conf.all.rp_filter=2` and `99-k3s-calico.conf` sets
`net.ipv4.conf.wg0.rp_filter=0`; last write wins and the ordering matters. Calico VXLAN over
WireGuard produces asymmetric paths that strict `rp_filter` drops. See
[`../bootstrap/host-prep/README.md`](../bootstrap/host-prep/README.md#rp_filter-caveat). Re-check
both values in `R5` — a new `procps` or `systemd-sysctl` is exactly the kind of thing that
reorders drop-in application.

---

## R3 — Quiesce the node

```bash
ssh ms-1 'kubectl cordon <node> && kubectl drain <node> --ignore-daemonsets \
  --delete-emptydir-data --timeout=10m'
```

For `vm-1`, re-read [`UPGRADE.md §U4.1`](UPGRADE.md#u41-about-draining-this-node) first and run
`scripts/dr/check-pdb-pinning.sh`. For `wk-1`, local-path PVs cannot be relocated — the drain
buys a graceful `SIGTERM` for Postgres, nothing more.

Then stop K3s so containerd is not mid-flight when glibc and systemd are replaced:

```bash
ssh <node> 'systemctl stop k3s 2>/dev/null || systemctl stop k3s-agent'
ssh <node> 'systemctl is-active k3s k3s-agent 2>/dev/null; true'
# expected: inactive
```

**Gate `R3-A`:** the node is `SchedulingDisabled`, carries no non-daemonset pods, and the K3s
unit is inactive.

---

## R4 — Run the release upgrade

Inside `tmux`, on the node:

```bash
do-release-upgrade
```

Answer deliberately:

| Prompt | Answer |
|---|---|
| Third-party sources will be disabled | Accept. K3s, containerd and Calico are **not** apt-managed on any node — verify with `dpkg -l \| grep -iE 'k3s\|containerd'`, which returns nothing — so nothing load-bearing is disabled. Re-enable anything you genuinely need in `R5`. |
| Replace a modified conffile? | **Keep the local version** for everything in the `R2` table. |
| Remove obsolete packages? | Yes, but read the list. Stop if it names `wireguard*`, `nftables`, anything `calico`, or the kernel you are currently running. |
| Restart services without asking? | Yes — the node is drained and K3s is stopped. |

Then reboot:

```bash
ssh <node> 'systemctl reboot'
```

**Gate `R4-A`:** `lsb_release -ds` reports `Ubuntu 26.04.1 LTS` and `uname -r` reports a 7.x
kernel.

---

## R5 — Re-assert host-prep before letting K3s back in

**Goal.** Prove the OS swap did not quietly revert a customisation. Do this **before** uncordoning —
a node that rejoins with `rp_filter` strict or `br_netfilter` unloaded breaks the data plane for
every pod scheduled onto it.

**R5.1 WireGuard first.** The API server's TLS SAN is only the WireGuard IP, so if `wg0` is down
`kubectl` fails from everywhere and it will look like a cluster-wide outage:

```bash
ssh <node> 'wg show; ip -brief addr show wg0'
# expected: interface up, its 172.27.15.0/24 address, peers with recent handshakes
```

**R5.2 Diff against the R2 hashes.**

```bash
ssh <node> 'md5sum /etc/sysctl.d/*.conf /etc/modules-load.d/*.conf \
  /etc/ssh/sshd_config.d/*.conf 2>/dev/null'
# expected: identical to R2. Any .dpkg-dist / .ucf-dist sibling means a prompt was answered wrong.
ssh <node> 'ls /etc/sysctl.d/*.dpkg-* /etc/ssh/sshd_config.d/*.dpkg-* 2>/dev/null; true'
# expected: empty
```

**R5.3 Check the values, not just the files.**

```bash
ssh <node> 'sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.wg0.rp_filter \
  vm.panic_on_oom vm.overcommit_memory kernel.panic'
# expected: all.rp_filter = 2, wg0.rp_filter = 0, panic_on_oom = 1, overcommit_memory = 1, panic = 10
ssh <node> 'lsmod | grep -E "br_netfilter|vxlan|overlay"'
# expected: all three present
```

`vm.panic_on_oom` is the one to watch. The kubelet overwrites it at startup, and
`oom-resilience-reassert.timer` is what puts it back — confirm the timer survived the upgrade:

```bash
ssh <node> 'systemctl is-enabled oom-resilience-reassert.timer; systemctl list-timers oom-resilience-reassert.timer --no-pager'
# expected: enabled, with a NEXT time
```

**R5.4 Firewall units.**

```bash
ssh <node> 'systemctl is-active homelab-fw-*.service k3s-api-lockdown*.service 2>/dev/null; true'
ssh vm-1 'systemctl is-active nftables.service edge-guardrail.service; nft list tables'
# expected: active/exited; both inet edgeguard and inet edge_guardrail present
ssh vm-1 'nft list table inet edgeguard | grep "dport 22"'
# expected: ip saddr <operator-home-IP>/32 tcp dport 22 accept
# A missing edgeguard table leaves public SSH open -- edge_guardrail alone does
# not restrict the source. Re-run prepare-host.sh; do NOT `systemctl restart
# nftables.service` (its ExecStop flushes Calico's tables too).
```

On `ms-1`, re-check that the lockdown chain's pod/service ACCEPT rules still sit at the **top** of
the chain, per [`UPGRADE.md §U2.6`](UPGRADE.md#u26-re-arm-the-firewall-lockdown). Read it with
`iptables -L -v -n` — without `-v` the interface column is hidden, and a rule that looks like a
blanket `ACCEPT` is usually `-i lo` or `-i wg0`.

**R5.5 Netfilter backend.** 26.04 may change the `iptables` alternative to the nft backend. K3s
and Calico each ship their own `iptables`, so this is informational rather than a blocker, but
record it:

```bash
ssh <node> 'update-alternatives --query iptables 2>/dev/null | grep Value; iptables -V'
```

---

## R6 — Start K3s and verify the node

```bash
ssh <node> 'systemctl start k3s 2>/dev/null || systemctl start k3s-agent'
ssh ms-1 'kubectl get nodes -o wide'
# expected: the node Ready, still v1.36.6+k3s1, now on the 7.x kernel
ssh ms-1 'kubectl -n calico-system get pods -o wide | grep <node>'
# expected: calico-node Running and 1/1 Ready on that node
```

Prove the data plane, not just the pod — `UPGRADE.md §UC.4` has the MTU and VXLAN checks:

```bash
ssh <node> 'ip -d link show vxlan.calico | grep -oE "mtu [0-9]+|vxlan"'
# expected: 1370, then vxlan. Empty or 1440 means stop and fix before uncordoning.
```

Then uncordon:

```bash
ssh ms-1 'kubectl uncordon <node>'
```

**Gate `R6-A`:** node `Ready`, `calico-node` healthy on it, VXLAN MTU 1370, and a test pod
scheduled onto it can reach a service IP.

Stop here and do the next node on another day if you want to. Unlike a K3s version bump, a
mixed-OS cluster carries no skew clock — 24.04 and 26.04 nodes coexist indefinitely.

---

## R7 — Repeat for the remaining nodes

`wk-2` → `vm-1` → `ms-1` → `wk-1`, each one `R0.2`/`R0.3` → `R1` → `R2` → `R3` → `R4` → `R5` → `R6`.

Two nodes need extra care:

**`vm-1`.** The Contabo cloud image's netplan and cloud-init are the fragile part — a release
upgrade can regenerate `/etc/netplan/*.yaml` and leave `eth0` unconfigured. Diff against
[`../bootstrap/host-prep/netplan/vm-1.yaml.example`](../bootstrap/host-prep/netplan/vm-1.yaml.example)
in `R5` and keep the VNC console open throughout. Every `*.kakde.eu` host is down for the whole
phase, because Traefik runs only here on `hostNetwork`.

**`ms-1`.** Take a fresh datastore tarball immediately before `R4`, not the one from `R0` — hours
of cluster state may have accumulated:

```bash
ssh ms-1 'systemctl stop k3s && \
  tar -czf /root/k3s-server-backup-$(date -u +%Y%m%d-%H%M).tar.gz -C /var/lib/rancher/k3s server && \
  ls -lh /root/k3s-server-backup-*.tar.gz'
# expected: a tarball of roughly 30-60 MB. Pull it to the laptop before going on.
```

K3s is already stopped by `R3`, so do not restart it just to stop it again.

---

## R8 — Close out

```bash
ssh ms-1 'kubectl get nodes -o wide'
# expected: 4 rows, all Ready, all v1.36.6+k3s1, all Ubuntu 26.04 kernels
ssh ms-1 'kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded'
# expected: empty
ssh ms-1 'kubectl get application -n argocd'
# expected: every Application Synced + Healthy
ssh ms-1 'kubectl get certificate,challenge,order -A'
# expected: all certificates Ready=True, no stuck challenges or orders
for h in kakde.eu notebook.kakde.eu argocd.kakde.eu keycloak.kakde.eu; do
  echo -n "$h "; curl -s -o /dev/null -w "%{http_code}\n" "https://$h"
done
```

Then refresh the DR pack, restore kured, and record the new baseline:

```bash
scripts/dr/snapshot-live-state.sh > deploy/dr/SNAPSHOT-$(date -u +%Y-%m-%d).md
scripts/dr/verify-snapshot.sh deploy/dr/SNAPSHOT-$(date -u +%Y-%m-%d).md
# expected: OK on every row
ssh ms-1 'kubectl -n kube-system patch ds kured --type=merge \
  -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"homelab.kakde.eu/role\":\"worker\"}}}}}"'
# expected: DESIRED back to 2
```

Update the **Status** table at the top of this file, this pack's [`README.md`](README.md), and
`packages-*.txt` if 26.04 renamed anything.

---

## Rollback, and why there is none

`do-release-upgrade` has no reverse. Once a node is on 26.04 the only way back to 24.04 is a
reinstall from [`RUNBOOK.md`](RUNBOOK.md) `L0` and a restore from the `U0` backups. None of these
hosts has a filesystem snapshot — root is ext4 on plain partitions on all four, with no LVM
thin-pool and no ZFS/btrfs.

That is the whole reason for the node order, the `tmux` requirement and the proven console path.
Per node, the realistic recovery is:

| Node | If it does not come back |
|---|---|
| `wk-2` | Rebuild from `RUNBOOK.md` `L0`–`L3`, rejoin. No persistent state to restore. |
| `vm-1` | Contabo VNC first. Failing that, reimage and re-run host-prep + agent install; Traefik re-schedules. |
| `ms-1` | Rebuild the server, restore `/var/lib/rancher/k3s/server` from the tarball. Agents rejoin with the preserved `node-token`. |
| `wk-1` | Rebuild, then restore all 7 Postgres databases. The longest path by a wide margin. |

**See also:** [`UPGRADE.md`](UPGRADE.md) · [`RUNBOOK.md`](RUNBOOK.md) · [`gates.md`](gates.md) ·
[`node-console-recovery.md`](node-console-recovery.md) ·
[`../bootstrap/host-prep/README.md`](../bootstrap/host-prep/README.md) ·
[`../bootstrap/host-prep/NODE-HARDENING.md`](../bootstrap/host-prep/NODE-HARDENING.md)
