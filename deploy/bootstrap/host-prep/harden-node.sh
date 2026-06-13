#!/usr/bin/env bash
#
# harden-node.sh — make a homelab K3s node survive memory pressure.
#
# WHY THIS EXISTS — the 2026-06-13 wk-1 outage
# --------------------------------------------
# wk-1 is installed as Ubuntu **Desktop** (GNOME/GDM, see packages-home.txt) and
# used as a K3s worker. On 2026-06-12 a graphical session ("session-c1.scope")
# grew to a 26 GB peak on the 30 GB node. With the database, go-judge (java),
# Calico and a host `ollama` (operator preference, not K8s-managed) also resident
# — and swap intentionally OFF (the K3s/kubelet default) — the kernel hit repeated
# node-wide OOM. Because `vm.panic_on_oom=0`, the kernel did not reboot; it thrashed
# until the box was unreachable (no SSH, no WireGuard) and had to be power-cycled by
# hand ~7 hours later.
#
# Kubernetes priority/QoS could NOT prevent this: a GNOME session and a host
# `ollama` are not pods, so the kubelet can neither limit nor evict them. The fix is
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
  log "purging GNOME desktop stack (apt)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y ubuntu-desktop ubuntu-desktop-minimal gnome-shell gdm3 \
      gnome-control-center gnome-remote-desktop 'cups*' avahi-daemon \
      modemmanager 2>/dev/null || true
  apt-get autoremove --purge -y 2>/dev/null || true
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
vm.panic_on_oom = 1
kernel.panic = 10
kernel.panic_on_oops = 1
# Keep a larger free reserve so the kernel/network stack don't starve before the
# OOM killer (or a kubelet eviction) can act.
vm.min_free_kbytes = 131072
CONF
log "wrote $SYSCTL"
sysctl --system >/dev/null
log "panic_on_oom=$(cat /proc/sys/vm/panic_on_oom) kernel.panic=$(cat /proc/sys/kernel/panic)"

log "done. mem now: $(free -h | awk '/Mem:/{print $3" used / "$2" total"}')  default-target: $(systemctl get-default)"
