# Node hardening — surviving memory pressure

Operator runbook. Written after the **2026-06-13 wk-1 outage**. Applies to the
home nodes (`ms-1`, `wk-1`, `wk-2`); the edge node (`ctb-edge-1`) is a headless
cloud VM and is not affected by the desktop issue below.

## What happened (root cause)

`wk-1` is an Ubuntu **Desktop** install used as a K3s worker. On 2026-06-12 a
graphical session (`session-c1.scope`, GNOME) grew to a **26 GB peak on the 30 GB
node**. With PostgreSQL, go-judge (java), Calico and a host `ollama` process also
resident — and **swap intentionally off** (the K3s/kubelet default) — the kernel
hit repeated **node-wide OOM**. Because `vm.panic_on_oom=0`, the kernel did not
reboot; it thrashed until the box was unreachable (no SSH, no WireGuard) and had to
be **power-cycled by hand**, ~7 hours later (08:19 → 15:42 CEST).

This was **resource exhaustion, not an attack** — auth logs showed only the
operator's key from `192.168.15.26`, zero failed/brute-force attempts, and Postgres
is ClusterIP-only (never exposed).

### Why the edge-ai-prep work did not prevent it

The priority-class / Guaranteed-QoS work (`deploy/platform/priorityclasses`,
PostgreSQL `data-tier`) operates **inside Kubernetes**. It did its job: when the
OOM killer ran, Postgres (oom_score_adj ≈ -997) was **spared** — the kernel killed
go-judge/Calico/journald instead, so the database was not corrupted. But a **GNOME
session and a host `ollama` are not pods** — the kubelet can neither limit nor evict
them. No in-cluster setting can stop a host process from taking the node down. The
fix has to be at the **host layer**.

## The fix

Two host-layer changes, both reversible, both consistent with the repo's swap-off
design:

1. **Boot headless** — `multi-user.target`, stop GDM, disable desktop cruft
   (avahi/cups/bluetooth/ModemManager/...). Removes the 26 GB-session risk and trims
   attack surface.
2. **OOM auto-recovery** — `vm.panic_on_oom=1` + `kernel.panic=10`, so a node that
   *does* run out of memory **reboots itself in ~10s** instead of wedging for hours.
   Installed on every node by `prepare-host.sh` (`sysctl/20-oom-resilience.conf`).

### Apply to a live node (now)

```bash
# from the operator laptop, per node:
ssh wk-1 'bash -s' < deploy/bootstrap/host-prep/harden-node.sh
ssh wk-2 'bash -s' < deploy/bootstrap/host-prep/harden-node.sh
ssh ms-1 'bash -s' < deploy/bootstrap/host-prep/harden-node.sh
```

Idempotent and non-disruptive (does not touch k3s, networking, or SSH). The desktop
stops immediately; it stays gone across reboots because the default target is now
`multi-user.target`.

To also reclaim disk by removing the packages (harder to undo — only on nodes that
will never want a GUI): add `--purge-desktop`.

**Reverse it:** `systemctl set-default graphical.target && systemctl start gdm`.

## Residual risks / operator decisions

- **`ollama` on wk-1 is unbounded.** It is a host process, not a pod, so nothing
  caps its memory. Before co-hosting it with the database long-term, either bound it
  with a systemd drop-in (`MemoryMax=8G` on `ollama.service`) **or** run the model
  in-cluster under `priorityClassName: ai-workload-low` with a hard memory limit (the
  plan in `deploy/HANDOFF-edge-ai-prep.md`). The in-cluster route is preferred — then
  the eviction ladder actually governs it.

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
