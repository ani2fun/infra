#!/usr/bin/env bash
#
# harden-node.sh — make a homelab K3s node survive memory pressure.
#
# WHY THIS EXISTS — the 2026-06-13 wk-1 outage
# --------------------------------------------
# wk-1 is installed as Ubuntu **Desktop** (GNOME/GDM, see packages-home.txt) and
# used as a K3s worker. On 2026-06-12 a graphical session ("session-c1.scope")
# grew to a 26 GB peak on the 30 GB node. With the database, go-judge (java),
# Calico and another host process also resident — and swap intentionally OFF
# (the K3s/kubelet default) — the kernel hit repeated
# node-wide OOM. Because `vm.panic_on_oom=0`, the kernel did not reboot; it thrashed
# until the box was unreachable (no SSH, no WireGuard) and had to be power-cycled by
# hand ~7 hours later.
#
# Kubernetes priority/QoS could NOT prevent this: a GNOME session and a host-level
# process are not pods, so the kubelet can neither limit nor evict them. The fix is
# at the host layer. This script does the two things that close the failure mode —
# both reversible, both consistent with the repo's swap-off design:
#
#   1. DESKTOP TEARDOWN  — boot headless (multi-user.target), stop GDM, disable the
#      non-network desktop cruft. Removes the 26 GB-session risk and trims attack
#      surface (avahi/cups/bluetooth/...). The single biggest win.
#   2. OOM AUTO-RECOVERY — sysctls so a node that DOES exhaust memory panics and
#      reboots itself (kernel.panic=10) instead of wedging. Turns a multi-hour
#      manual outage into a ~1-minute self-heal. (Mirrors sysctl/20-oom-resilience.conf,
#      which prepare-host.sh installs on fresh builds.)
#      The sysctl file alone does nothing: the kubelet resets vm.panic_on_oom to 0
#      at every start. This script also installs oom-resilience-reassert.timer,
#      which puts the value back. See NODE-HARDENING.md for the full story.
#
# Swap is NOT added: the repo runs swap-off on purpose (prepare-host.sh disables it).
# The headroom comes from removing the desktop, not from swap.
#
# Optional opt-in:
#   --purge-desktop   apt purge the GNOME stack (frees disk; harder to undo than a
#                     stop/disable — only on nodes that will never want the GUI).
#
# Idempotent. Run as root on each node:  ssh <node> 'bash -s' < harden-node.sh
# Reverse the defaults:  systemctl set-default graphical.target && systemctl start gdm
#
set -euo pipefail

PURGE_DESKTOP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-desktop) PURGE_DESKTOP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;36m[harden]\033[0m %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

log "node: $(hostname)  mem: $(free -h | awk '/Mem:/{print $2" total, "$3" used"}')"

# ---------------------------------------------------------------------------
# 1. DESKTOP TEARDOWN (reversible)
# ---------------------------------------------------------------------------
if [[ "$(systemctl get-default)" != "multi-user.target" ]]; then
  log "set-default multi-user.target (was $(systemctl get-default))"
  systemctl set-default multi-user.target
else
  log "default target already multi-user.target"
fi

# GDM is a 'static' unit (pulled by graphical.target), so it cannot be `disable`d —
# stopping it + the headless default target is what keeps the GUI from starting.
if systemctl is-active --quiet gdm 2>/dev/null; then
  log "stopping gdm (reclaims the greeter / blocks GUI sessions)"
  systemctl stop gdm || true
fi

# Non-network desktop cruft. Deliberately DOES NOT touch NetworkManager,
# wpa_supplicant, systemd-resolved, ssh, k3s, containerd or wireguard.
CRUFT=(bluetooth cups cups-browsed avahi-daemon ModemManager gnome-remote-desktop \
       switcheroo-control power-profiles-daemon kerneloops whoopsie)
for svc in "${CRUFT[@]}"; do
  if [[ -n "$(systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null)" ]]; then
    systemctl disable --now "${svc}.service" >/dev/null 2>&1 && log "disabled ${svc}" || true
  fi
done

if [[ "$PURGE_DESKTOP" -eq 1 ]]; then
  # CRITICAL: on home nodes NetworkManager manages the primary link (netplan
  # renderer: NetworkManager) and systemd-networkd is inactive. The desktop
  # metapackages pull network-manager, so a naive `autoremove` after purging the
  # desktop could DELETE network-manager and strand the node with no network — the
  # one outcome worse than today. Pin the network/boot/ssh essentials as 'manual'
  # so autoremove can never treat them as orphans, then verify before removing.
  log "pinning network/boot/ssh packages so autoremove cannot delete them"
  apt-mark manual network-manager network-manager-config-connectivity-ubuntu \
      netplan.io openssh-server wpasupplicant linux-generic-hwe-24.04 \
      >/dev/null 2>&1 || true
  export DEBIAN_FRONTEND=noninteractive
  log "purging GNOME desktop stack"
  apt-get purge -y ubuntu-desktop ubuntu-desktop-minimal gnome-shell 'gnome-shell-*' \
      gdm3 gnome-control-center gnome-remote-desktop 2>/dev/null || true
  # Belt-and-suspenders: abort autoremove if it would still touch an essential.
  if apt-get autoremove --purge -s 2>/dev/null \
       | grep -qE '^Remv (network-manager|netplan|openssh-server|linux-image|linux-generic|systemd|wpasupplicant)\b'; then
    echo "WARN: autoremove would touch a critical package — SKIPPED. Inspect by hand:" >&2
    echo "      apt-get autoremove --purge -s" >&2
  else
    apt-get autoremove --purge -y 2>/dev/null || true
  fi
  log "network-manager still installed: $(dpkg -l network-manager 2>/dev/null | awk '/^ii/{print $3}' || echo MISSING)"
fi

# ---------------------------------------------------------------------------
# 2. OOM AUTO-RECOVERY sysctls (reversible: rm the file + sysctl --system)
# ---------------------------------------------------------------------------
SYSCTL=/etc/sysctl.d/20-oom-resilience.conf
cat > "$SYSCTL" <<'CONF'
# Homelab node OOM resilience — deploy/bootstrap/host-prep/harden-node.sh
# Panic (and, with kernel.panic>0, auto-reboot) on a *node-wide* OOM. Value 1 does
# NOT fire for cgroup/pod-limit OOMs (those still kill only the offending pod) — only
# when the whole node is out of memory, exactly the wk-1 wedge we want to self-heal.
#
# This file is NOT sufficient on its own: the kubelet enforces vm.panic_on_oom=0 at
# every start unless --protect-kernel-defaults is set, and does so silently. The
# oom-resilience-reassert timer installed below is what makes the value stick.
vm.panic_on_oom = 1
kernel.panic = 10
kernel.panic_on_oops = 1
# Keep a larger free reserve so the kernel/network stack don't starve before the
# OOM killer (or a kubelet eviction) can act.
vm.min_free_kbytes = 131072
# Declared so this file states the live truth; the kubelet sets the same value
# anyway, so writing it here changes nothing today.
vm.overcommit_memory = 1
CONF
log "wrote $SYSCTL"

# Magic SysRq is a separate file (home nodes only): a wedged-but-alive node can be
# rebooted SAFELY from a physically-attached keyboard (Alt+SysRq+R,E,I,S,U,B) instead
# of a hard power cut that risks the node-local Postgres data. The edge node is
# headless and keeps its image's narrower kernel.sysrq=176.
# See deploy/dr/node-console-recovery.md.
cat > /etc/sysctl.d/21-sysrq-console.conf <<'CONF'
# Homelab home nodes — deploy/bootstrap/host-prep/harden-node.sh
kernel.sysrq = 1
CONF
log "wrote /etc/sysctl.d/21-sysrq-console.conf"

sysctl --system >/dev/null

# ---------------------------------------------------------------------------
# 2b. RE-ASSERT TIMER — without this, the sysctl above is cosmetic
# ---------------------------------------------------------------------------
# systemd-sysctl applies the file correctly at boot; k3s then starts and the
# kubelet's container manager rewrites vm.panic_on_oom to 0. The overwrite is
# silent (V(2) log line, which k3s never prints), which is why every node reported
# panic_on_oom=0 from 2026-06-13 to 2026-11-19 while the repo claimed 1.
cat > /etc/systemd/system/oom-resilience-reassert.service <<'UNIT'
[Unit]
Description=Re-apply OOM resilience sysctls after the kubelet overwrites them
After=k3s.service k3s-agent.service
ConditionPathExists=/etc/sysctl.d/20-oom-resilience.conf

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl --quiet --load=/etc/sysctl.d/20-oom-resilience.conf
ExecStartPost=/bin/sh -c 'grep -qx 1 /proc/sys/vm/panic_on_oom || { echo "vm.panic_on_oom did not stick after re-apply" >&2; exit 1; }'
UNIT
cat > /etc/systemd/system/oom-resilience-reassert.timer <<'UNIT'
[Unit]
Description=Periodically re-assert OOM resilience sysctls against the kubelet

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now oom-resilience-reassert.timer
systemctl start oom-resilience-reassert.service || true
log "installed oom-resilience-reassert.timer ($(systemctl is-active oom-resilience-reassert.timer))"

if [[ "$(cat /proc/sys/vm/panic_on_oom)" == "1" ]]; then
  log "OOM self-heal ON: panic_on_oom=1 kernel.panic=$(cat /proc/sys/kernel/panic)s"
else
  log "OOM self-heal OFF: panic_on_oom=$(cat /proc/sys/vm/panic_on_oom) — the kubelet holds it;"
  log "  the timer restores it within 5 min. Re-check with gate L0-D."
fi

log "done. mem now: $(free -h | awk '/Mem:/{print $3" used / "$2" total"}')  default-target: $(systemctl get-default)"
