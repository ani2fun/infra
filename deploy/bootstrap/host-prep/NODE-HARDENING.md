# Node hardening — surviving memory pressure

Operator runbook. Written after the **2026-06-13 wk-1 outage**. Applies to the
home nodes (`ms-1`, `wk-1`, `wk-2`); the edge node (`ctb-edge-1`) is a headless
cloud VM and is not affected by the desktop issue below.

To recover a node that is already down/unreachable, see
[`deploy/dr/node-console-recovery.md`](../../dr/node-console-recovery.md).

## What happened (root cause)

The home nodes were installed as Ubuntu **Desktop** and used as K3s nodes. On
2026-06-12 a graphical session (`session-c1.scope`, GNOME) grew to a **26 GB peak
on the 30 GB wk-1**. With PostgreSQL, go-judge (java), Calico and another host
process also resident — and **swap intentionally off** (the K3s/kubelet default) —
the kernel hit repeated **node-wide OOM**. Because `vm.panic_on_oom=0`, the kernel
did not reboot; it thrashed until the box was unreachable (no SSH, no WireGuard) and
had to be **power-cycled by hand**, ~7 hours later (08:19 → 15:42 CEST).

This was **resource exhaustion, not an attack** — auth logs showed only the
operator's key from `192.168.15.26`, zero failed/brute-force attempts, and Postgres
is ClusterIP-only (never exposed).

### Why Kubernetes limits did not prevent it

The priority-class / Guaranteed-QoS work (`deploy/platform/priorityclasses`,
PostgreSQL `data-tier`) operates **inside Kubernetes**. It did its job: when the
OOM killer ran, Postgres (oom_score_adj ≈ -997) was **spared** — the kernel killed
go-judge/Calico/journald instead, so the database was not corrupted. But a **GNOME
session and any host-level process are not pods** — the kubelet can neither limit
nor evict them. No in-cluster setting can stop a host process from taking the node
down. The fix has to be at the **host layer**.

## The fix

Two host-layer changes, both reversible, both consistent with the repo's swap-off
design:

1. **Boot headless** — `multi-user.target`, stop GDM, disable desktop cruft
   (avahi/cups/bluetooth/ModemManager/...). Removes the 26 GB-session risk and trims
   attack surface. On wk-1 the desktop packages were also purged (`--purge-desktop`).
2. **OOM auto-recovery** — `vm.panic_on_oom=1` + `kernel.panic=10`, so a node that
   *does* run out of memory **reboots itself in ~10 s** instead of wedging. Plus
   `kernel.sysrq=1` for a safe manual reboot from the console. Installed on every
   node by `prepare-host.sh` (`sysctl/20-oom-resilience.conf`).

### Apply to a live node

```bash
# from the operator laptop, per node:
ssh wk-1 'bash -s' < deploy/bootstrap/host-prep/harden-node.sh                  # disable + sysctls
ssh wk-1 'bash -s' < deploy/bootstrap/host-prep/harden-node.sh -- --purge-desktop # also remove packages
```

Idempotent and non-disruptive (does not touch k3s, networking, or SSH). The desktop
stops immediately; it stays gone across reboots because the default target is now
`multi-user.target`. **`--purge-desktop`** pins network/boot/ssh packages as `manual`
first so `autoremove` can't strand the node — important, because NetworkManager
manages the primary link on the home nodes.

**Reverse a non-purged node:** `systemctl set-default graphical.target && systemctl start gdm`.

## Residual risks / operator decisions

- **Unmanaged host processes are unbounded.** Anything run directly on the host
  (not as a pod) escapes Kubernetes' memory governance. If you run such a process on
  a node that co-hosts the database, bound it with a systemd drop-in
  (e.g. `MemoryMax=8G` on its `.service`) so it cannot OOM the node. Prefer running
  workloads in-cluster with a hard memory limit so the eviction ladder governs them.

- **Kubelet eviction reservations (optional, more invasive).** To have the kubelet
  shed pods *before* the kernel OOM-killer fires, reserve headroom in
  `/etc/rancher/k3s/config.yaml` and restart the agent (brief):
  ```yaml
  kubelet-arg:
    - "system-reserved=memory=512Mi"
    - "kube-reserved=memory=512Mi"
    - "eviction-hard=memory.available<500Mi"
  ```
  This only helps against *pod* pressure; it would not have stopped the 26 GB desktop
  session. Apply deliberately, one node at a time, in a quiet window.

- **PostgreSQL is a single point of failure.** It is one replica on node-local
  (`local-path`) storage pinned to `wk-1`: if `wk-1` is down, the DB is down and
  cannot reschedule. OOM auto-recovery shrinks the outage from hours to ~1 minute,
  but the SPOF remains by design. Keep the DR pack (`deploy/dr/`) current; a
  replicated/standby DB is out of scope for this homelab.

## Node self-recovery — watchdog and reboot window (2026-07-18)

Added after `wk-1` went down at 16:57 and did not return until 18:33 — **96 minutes**, during
which `synapse.kakde.eu` was down because Postgres lives on that node's local storage.

**What the logs showed, and what they ruled out.** No kernel panic, no MCE, no thermal event, no
node-level OOM, and — decisively — *no shutdown sequence at all*: the journal stops mid-line and
the last kernel message predates the death by ten hours. No ACPI power-button event either. That
signature is power loss or a hard hang, not software. Two things people reach for first were
false leads: the `panic`/`oops` grep hits are `drm panic` (a boot-time handler registration) and
`whoopsie` (Ubuntu's crash reporter), and the kernel upgrade that day installed at 06:51 without
rebooting — the node ran ten more hours before dying, then merely *booted into* the new kernel.

**Why it stayed down.** These are bare-metal mini PCs (`wk-1` is a GMKtec NucBox K9). There is no
hypervisor to restart them, and nothing else was configured to. That is the whole answer.

Three layers now address it, and only two are in this repo:

| Layer | Where | Covers |
|---|---|---|
| BIOS "Restore on AC Power Loss" → **Power On** | **Manual, per machine** | Power loss. Cannot be set from the OS — `fwupdmgr` reports "This system doesn't support firmware settings" on these boards. |
| Hardware watchdog (`iTCO_wdt` + `RuntimeWatchdogSec=60`) | `modules-load/watchdog.conf`, `systemd/10-watchdog.conf` | A hard hang that stops the kernel scheduling. The board resets itself after 60s. |
| Staggered unattended-upgrade reboot window | `apt/52unattended-upgrades-reboot` | Kernels being activated by an unplanned restart at an arbitrary time. |

**Watchdog status per node.** `wk-1` runs it for real (Intel PCH TCO v6, `state=active`,
`timeout=60`). **`wk-2` cannot**: its firmware locks the TCO off and the driver refuses to
register, logging `unable to reset NO_REBOOT flag, device disabled by hardware/BIOS`. The config
is installed anyway so it activates if that BIOS option is ever enabled. Deliberately no `softdog`
fallback — a software watchdog is a kernel timer, so the very hang it would need to catch also
stops it firing; installing one would be reassurance rather than cover.

**Reboot windows are staggered** (`wk-1` 03:30, `wk-2` 04:30) so an upgrade night never takes two
nodes at once. `prepare-host.sh` reads `UPGRADE_REBOOT_TIME` (default `03:30`).

**Still open, and bigger than any of this:** `postgresql-0` is bound to `wk-1` by node-local
storage and `synapse-go-judge` is pinned there by `nodeSelector`, so the database shares one mini
PC with the sandbox that executes arbitrary user-submitted code. Whatever wedges that box takes
the whole platform with it, and Kubernetes cannot reschedule around it. The watchdog shortens
that outage; it does not remove the single point of failure.
