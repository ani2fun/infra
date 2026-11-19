# Node hardening — surviving memory pressure

Operator runbook. Written after the **2026-06-13 wk-1 outage**. The desktop
teardown below applies to the home nodes (`ms-1`, `wk-1`, `wk-2`) only; the edge
node (`ctb-edge-1`) is a headless cloud VM with no desktop. **OOM auto-recovery
applies to all four nodes** (the edge was added on 2026-11-19 — see
[Edge node](#edge-node-ctb-edge-1)).

> **Read [The kubelet silently reverts `vm.panic_on_oom`](#the-kubelet-silently-reverts-vmpanic_on_oom)
> before trusting anything in this file about OOM self-heal.** From 2026-06-13 to
> 2026-11-19 this document stated the self-heal as fact while it was off on every
> node.

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
   `kernel.sysrq=1` on the home nodes for a safe manual reboot from the console
   (`sysctl/21-sysrq-console.conf`). Installed on every node by `prepare-host.sh`
   (`sysctl/20-oom-resilience.conf`) — **and the sysctl file alone does not work.**
   The kubelet resets `vm.panic_on_oom` to 0 at every start;
   `systemd/oom-resilience-reassert.timer` is what makes the value stick. The next
   section is the whole story.

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

## The kubelet silently reverts `vm.panic_on_oom` (found 2026-11-19)

**The self-heal described above had never been in effect on any node.** On
2026-11-19 all four nodes reported `vm.panic_on_oom = 0` while
`/etc/sysctl.d/20-oom-resilience.conf` said `1` on `ms-1`, `wk-1` and `wk-2`.
Everything about the file was correct — right content, right path, and
`journalctl -u systemd-sysctl -b` showed a clean run with no error. The value
was being changed *after* boot.

### What does it

The kubelet enforces its own expected kernel values when its container manager
starts (`setupKernelTunables`). Unless `--protect-kernel-defaults=true` is set
it takes the `KernelTunableModify` branch and **overwrites** any mismatch. The
set it enforces is:

| Sysctl | Kubelet wants | This repo wants |
|---|---|---|
| `vm.overcommit_memory` | 1 | 1 (agrees) |
| `vm.panic_on_oom` | **0** | **1** — the only conflict |
| `kernel.panic` | 10 | 10 (agrees) |
| `kernel.panic_on_oops` | 1 | 1 (agrees) |
| `kernel.keys.root_maxkeys` | 1000000 | unset |
| `kernel.keys.root_maxbytes` | 25000000 | unset |

### How it was proved, given the journal shows nothing

The overwrite is logged at `V(2)`, and k3s runs the kubelet at its default
verbosity, so **there is no journal line to find**. Looking for one is a dead
end. The proof is the live values themselves:

- `vm.overcommit_memory = 1` on all four nodes, while **nothing** in
  `/etc/sysctl.conf`, `/etc/sysctl.d/`, `/usr/lib/sysctl.d/` or `/run/sysctl.d/`
  sets it. The Ubuntu default is 0. Only the kubelet writes that value.
- `kernel.panic_on_oops = 1` on `vm-1`, which at the time had no
  `20-oom-resilience.conf` at all and whose only panic-related file
  (`10-panic.conf`) sets `kernel.panic` and nothing else.
- The live set matches the kubelet's expected set **exactly**, including the one
  value that contradicts the repo.
- Boot ordering fits: `systemd-sysctl.service` finishes within a second of boot,
  k3s starts 10–30 s later (`ms-1` 22:09:04 → 22:09:36; `wk-1` 09:31:16 →
  09:31:27). Correct file, correctly applied, then overwritten.

No K3s flag anywhere sets `--protect-kernel-defaults`. There is no
`/etc/rancher/k3s/config.yaml` on any node — every K3s flag lives in
`INSTALL_K3S_EXEC` in `deploy/bootstrap/k3s/install-*.sh`.

### The fix, and the option that was rejected

Two ways to stop the kubelet winning:

**Rejected — `--protect-kernel-defaults=true`.** It makes the kubelet *fail to
start* on a mismatch instead of overwriting, which is strictly more honest. Two
reasons it is wrong here:

1. `ms-1` is the **only** control-plane node. A kubelet that refuses to start
   there is an API server that refuses to start — the cluster is down, and the
   failure happens at boot, when nobody is watching.
2. It is not a one-line change. The flag makes the kubelet *stop setting* the
   whole table above, so every value in it must already be present at boot or
   the kubelet errors out. That ties node boot to a list of kernel defaults that
   a kernel upgrade or a future kubelet release can extend without warning.

**Chosen — re-apply after the kubelet has settled.**
`systemd/oom-resilience-reassert.{service,timer}` runs
`sysctl --load=/etc/sysctl.d/20-oom-resilience.conf` at `OnBootSec=2min` and
then every `5min`. The service's `ExecStartPost` re-reads
`/proc/sys/vm/panic_on_oom` and exits non-zero if the value did not stick, so a
silent failure becomes a failed unit.

It polls rather than ordering itself `After=k3s-agent.service` because the
kubelet re-applies its values at **every** start — a `systemctl restart
k3s-agent`, a k3s upgrade, a crash-loop restart, a kured reboot. systemd does
not reliably propagate automatic restarts to a `WantedBy=` unit, so an ordered
one-shot would quietly stop covering exactly the cases that matter. One
idempotent `sysctl` write a minute is cheaper than that gap.

**The cost, stated plainly:** for up to 5 minutes after a kubelet start the node
has no OOM self-heal. That window is accepted. It is small against the
multi-hour wedge this protects against, and unlike `protect-kernel-defaults` it
cannot leave a node unable to boot.

### Edge node (ctb-edge-1)

`vm-1` had never received `20-oom-resilience.conf`. That was an oversight, not a
decision, and it has been corrected — the edge now gets the same file.

The tempting justification ("it is a cloud VM, the provider recovers it") does
not hold: Contabo offers a console and a manual reset, not a watchdog that
notices a wedged guest. `vm-1` in fact has the **weakest** recovery of the four
nodes — no hardware watchdog (`/dev/watchdog` does not exist), no BIOS
restore-on-AC-power to inherit, and it is deliberately excluded from kured. It
is also the only public entry point, so a wedge there takes every `*.kakde.eu`
host down.

It does **not** get `kernel.sysrq = 1`. That was split out into
`sysctl/21-sysrq-console.conf` (home nodes only): SysRq is reached from an
attached keyboard, the edge is headless, and the Contabo image ships a
deliberately narrower `kernel.sysrq = 176` in `/etc/sysctl.d/10-magic-sysrq.conf`
that a `20-`prefixed file would have overridden for no gain.

### Verifying it, now and after every reboot

Gate **L0-D** in [`../../dr/gates.md`](../../dr/gates.md) checks the *live*
value, the timer and the unit's result on all four nodes. **L0-E** checks that
nothing has started setting `--protect-kernel-defaults`. Checking the file
instead of `/proc/sys/vm/panic_on_oom` is what let this go unnoticed for five
months — do not repeat it.

## Residual risks / operator decisions

- **Unmanaged host processes are unbounded.** Anything run directly on the host
  (not as a pod) escapes Kubernetes' memory governance. If you run such a process on
  a node that co-hosts the database, bound it with a systemd drop-in
  (e.g. `MemoryMax=8G` on its `.service`) so it cannot OOM the node. Prefer running
  workloads in-cluster with a hard memory limit so the eviction ladder governs them.

- **Kubelet eviction reservations (optional, more invasive).** To have the kubelet
  shed pods *before* the kernel OOM-killer fires, reserve headroom with
  `--kubelet-arg` flags and reinstall the agent. There is **no
  `/etc/rancher/k3s/config.yaml` on these nodes** — every K3s flag lives in
  `INSTALL_K3S_EXEC` in `deploy/bootstrap/k3s/install-*.sh`, so the change goes
  there and the node is re-run through its install script:
  ```bash
  INSTALL_K3S_EXEC="agent \
    ... \
    --kubelet-arg=system-reserved=memory=512Mi \
    --kubelet-arg=kube-reserved=memory=512Mi \
    --kubelet-arg=eviction-hard=memory.available<500Mi"
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
| Drained reboot after a kernel update (kured, since 2026-11-18; before that a staggered unattended-upgrade reboot) | `deploy/platform/kured/`, `apt/52unattended-upgrades-reboot` | Kernels being activated by an unplanned restart at an arbitrary time. |

**Watchdog status per node.** `wk-1` runs it for real (Intel PCH TCO v6, `state=active`,
`timeout=60`). **`wk-2` cannot**: its firmware locks the TCO off and the driver refuses to
register, logging `unable to reset NO_REBOOT flag, device disabled by hardware/BIOS`. The config
is installed anyway so it activates if that BIOS option is ever enabled. Deliberately no `softdog`
fallback — a software watchdog is a kernel timer, so the very hang it would need to catch also
stops it firing; installing one would be reassurance rather than cover.

**Worker reboots go through kured (changed 2026-11-18).** Until then, unattended-upgrades rebooted
`wk-1` at 03:30 and `wk-2` at 04:30 with no drain. Pods were killed in place and restarted into
their old state on the same node. After every `wk-2` kernel reboot from September to November,
Argo CD's repo-server crash-looped on `/bin/ln: Already exists`, and no deploy happened until
someone restarted it by hand. Now `Automatic-Reboot` is `"false"`. The kured DaemonSet
([`../../platform/kured/`](../../platform/kured/kustomization.yaml)) runs on
`homelab.kakde.eu/role=worker` nodes. It sees `/var/run/reboot-required`, waits for the
03:00–05:00 Europe/Paris window, takes a cluster-wide lock (so only one node reboots at a time),
drains, reboots, and uncordons. A drain that does not finish in 10 minutes cancels that reboot
until the next check. `kubectl describe node` shows kured's annotations.

**`ms-1` and `vm-1` are deliberately excluded** from that automation. `vm-1` is the only public
entry point, so an unattended 03:30 reboot is an unannounced outage of every `*.kakde.eu` host;
`ms-1` is the only API server, with no second control-plane node to carry the cluster. Neither
would be drained first: kured runs only on the worker nodes. The cost of that choice is real
and was visible by 2026-08-12: both nodes had been carrying pending kernel reboots for 11 and 17
weeks respectively. The countermeasure is the operator-run patching section in
[`../../dr/UPGRADE.md`](../../dr/UPGRADE.md) plus a recurring reminder — not automation that
reboots the control plane and the public edge with nobody watching.

**Still open, and bigger than any of this:** `postgresql-0` is bound to `wk-1` by node-local
storage and `synapse-go-judge` is pinned there by `nodeSelector`, so the database shares one mini
PC with the sandbox that executes arbitrary user-submitted code. Whatever wedges that box takes
the whole platform with it, and Kubernetes cannot reschedule around it. The watchdog shortens
that outage; it does not remove the single point of failure.
