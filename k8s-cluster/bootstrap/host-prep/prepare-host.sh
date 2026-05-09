#!/usr/bin/env bash
# Layer 0 host preparation for the homelab K3s cluster.
#
# Runs as root on a fresh Ubuntu 24.04.4 LTS install. Detects the node role
# from /etc/hostname and applies the right packages, sysctl tuning, kernel
# modules, SSH dropin, NTP, and timezone for that role.
#
# Idempotent. Safe to re-run.
#
# Expected hostname values:
#   ms-1, wk-1, wk-2, ctb-edge-1
#
# After this script finishes, proceed to ../wireguard/README.md.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- guards ----------

if [[ "$(id -u)" != "0" ]]; then
  echo "must run as root" >&2
  exit 1
fi

if ! grep -q "Ubuntu 24.04" /etc/os-release; then
  echo "expected Ubuntu 24.04 LTS, got:" >&2
  grep PRETTY_NAME /etc/os-release >&2
  echo "set FORCE_OS=1 to override (not recommended)" >&2
  if [[ "${FORCE_OS:-0}" != "1" ]]; then exit 1; fi
fi

HOSTNAME="$(cat /etc/hostname | tr -d '[:space:]')"

case "$HOSTNAME" in
  ms-1|wk-1|wk-2)
    ROLE="home"
    ;;
  ctb-edge-1)
    ROLE="edge"
    ;;
  *)
    echo "unrecognised hostname: $HOSTNAME" >&2
    echo "expected one of: ms-1, wk-1, wk-2, ctb-edge-1" >&2
    exit 1
    ;;
esac

echo "==> host: $HOSTNAME   role: $ROLE"

# ---------- packages ----------

read_pkglist() {
  # Strip comments + blanks. Print one package per line.
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk 'NF && $1 !~ /^#/ {print $1}' "$f"
}

PKGS=()
mapfile -t -O "${#PKGS[@]}" PKGS < <(read_pkglist "$ROOT/packages-common.txt")
if [[ "$ROLE" == "home" ]]; then
  mapfile -t -O "${#PKGS[@]}" PKGS < <(read_pkglist "$ROOT/packages-home.txt")
else
  mapfile -t -O "${#PKGS[@]}" PKGS < <(read_pkglist "$ROOT/packages-edge.txt")
fi

# wk-2 prefers chronyd; everywhere else uses systemd-timesyncd
case "$HOSTNAME" in
  wk-2) PKGS+=("chrony") ;;
esac

echo "==> apt update"
DEBIAN_FRONTEND=noninteractive apt-get update -qq

echo "==> apt install (${#PKGS[@]} packages)"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PKGS[@]}"

# ---------- swap off ----------

echo "==> disabling swap"
swapoff -a || true
# Comment out any active swap entry (keeps the line for reference)
if grep -qE '^[^#].*\sswap\s' /etc/fstab; then
  sed -i.bak -E 's/^([^#].*\sswap\s.*)$/# \1   # disabled by prepare-host.sh/' /etc/fstab
fi

# ---------- sysctl ----------

echo "==> installing sysctl files"
install -m 0644 "$ROOT/sysctl/99-k3s-calico.conf" /etc/sysctl.d/99-k3s-calico.conf

# Reuse the wireguard sysctl from ../wireguard/. If the source is not
# present (e.g. the operator only copied host-prep/), warn but continue;
# the file may already be in place from a previous run.
if [[ -f "$ROOT/../wireguard/99-wireguard.conf" ]]; then
  install -m 0644 "$ROOT/../wireguard/99-wireguard.conf" /etc/sysctl.d/99-wireguard.conf
elif [[ ! -f /etc/sysctl.d/99-wireguard.conf ]]; then
  echo "WARN: bootstrap/wireguard/99-wireguard.conf not found, and no live copy exists" >&2
  echo "      copy it manually before running WireGuard layer" >&2
fi

if [[ "$ROLE" == "edge" ]]; then
  install -m 0644 "$ROOT/sysctl/10-panic.conf" /etc/sysctl.d/10-panic.conf
  install -m 0644 "$ROOT/sysctl/99-cloudimg-ipv6.conf" /etc/sysctl.d/99-cloudimg-ipv6.conf
fi

sysctl --system >/dev/null

# ---------- kernel modules ----------

echo "==> installing kernel module loaders"
install -m 0644 "$ROOT/modules-load/k3s-calico.conf" /etc/modules-load.d/k3s-calico.conf
if [[ "$ROLE" == "home" ]]; then
  install -m 0644 "$ROOT/modules-load/k8s.conf" /etc/modules-load.d/k8s.conf
fi

for m in br_netfilter vxlan overlay; do
  modprobe "$m" 2>/dev/null || true
done

# ---------- ssh dropin ----------

echo "==> installing sshd dropin"
mkdir -p /etc/ssh/sshd_config.d
if [[ "$ROLE" == "home" ]]; then
  install -m 0644 "$ROOT/ssh/99-root-login.conf" /etc/ssh/sshd_config.d/99-root-login.conf
else
  install -m 0644 "$ROOT/ssh/60-cloudimg-settings.conf" /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
fi
sshd -t  # validate before reload
systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service

# ---------- ntp + timezone ----------

if [[ "$HOSTNAME" == "wk-2" ]]; then
  echo "==> NTP: chrony"
  systemctl disable --now systemd-timesyncd 2>/dev/null || true
  systemctl enable --now chrony.service
else
  echo "==> NTP: systemd-timesyncd"
  systemctl enable --now systemd-timesyncd
fi

if [[ "$ROLE" == "home" ]]; then
  timedatectl set-timezone Europe/Paris
else
  timedatectl set-timezone Europe/Berlin
fi

# ---------- per-node firewall systemd units ----------

install_firewall_unit() {
  local sh="$1"
  local svc="$2"
  install -m 0755 "$ROOT/firewall/${sh}" "/usr/local/sbin/${sh}"
  install -m 0644 "$ROOT/firewall/${svc}" "/etc/systemd/system/${svc}"
  systemctl daemon-reload
  systemctl enable --now "${svc}"
}

install_firewall_unit_no_driver() {
  local svc="$1"
  install -m 0644 "$ROOT/firewall/${svc}" "/etc/systemd/system/${svc}"
  systemctl daemon-reload
  systemctl enable --now "${svc}"
}

case "$HOSTNAME" in
  ms-1)
    echo "==> ms-1 firewall units"
    install_firewall_unit "homelab-fw-ms1.sh" "homelab-fw-ms1.service"
    install_firewall_unit "k3s-api-lockdown.sh" "k3s-api-lockdown.service"
    install_firewall_unit_no_driver "k3s-api-lockdown-allow-cluster.service"
    ;;
  ctb-edge-1)
    echo "==> edge firewall units"
    install_firewall_unit "homelab-fw-edge.sh" "homelab-fw-edge.service"
    if [[ ! -f /etc/edge-allowlist.env ]]; then
      install -m 0640 "$ROOT/firewall/edge-allowlist.env.example" /etc/edge-allowlist.env
      echo "    /etc/edge-allowlist.env created from example."
      echo "    EDIT IT NOW and set ADMIN_SSH_ALLOW_IP before running edge-guardrail."
    fi
    # edge-guardrail itself lives in platform/traefik/ -- not installed here.
    ;;
  wk-1|wk-2)
    # No host firewall units on the workers (yet).
    ;;
esac

# ---------- verification ----------

echo
echo "==> verification"
echo
echo "[hostname]   $(hostname)"
echo "[kernel]     $(uname -r)"
echo "[swap]       $(swapon --show=NAME --noheadings | tr '\n' ' ')${BASH_LINENO:+}"
swap_show="$(swapon --show=NAME --noheadings || true)"
if [[ -z "$swap_show" ]]; then echo "[swap-state] OFF (good)"; else echo "[swap-state] ON  (bad: $swap_show)"; fi

for k in net.ipv4.ip_forward net.ipv6.conf.all.forwarding \
         net.bridge.bridge-nf-call-iptables \
         net.ipv4.conf.all.rp_filter \
         net.ipv4.conf.wg0.rp_filter ; do
  v="$(sysctl -n "$k" 2>/dev/null || echo '?')"
  printf '[sysctl] %-40s = %s\n' "$k" "$v"
done

for m in br_netfilter vxlan overlay; do
  if lsmod | awk '{print $1}' | grep -qx "$m"; then
    echo "[module] $m loaded"
  else
    echo "[module] $m NOT loaded"
  fi
done

echo "[ntp]        $(timedatectl show -p NTP --value) (NTPSynchronized=$(timedatectl show -p NTPSynchronized --value))"
echo "[tz]         $(timedatectl show -p Timezone --value)"
sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication)' | sed 's/^/[ssh]      /'

echo
echo "==> done. Next: bootstrap WireGuard. See ../wireguard/README.md"
