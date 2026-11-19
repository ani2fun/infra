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
# OOM auto-recovery on every node (self-heal instead of wedging — see 20-oom-resilience.conf).
install -m 0644 "$ROOT/sysctl/20-oom-resilience.conf" /etc/sysctl.d/20-oom-resilience.conf
# Raised mmap-region ceiling. Elasticsearch (deploy/apps/dblab) refuses to start below 262144,
# and the Ubuntu default is 65530 — see 10-map-count.conf.
install -m 0644 "$ROOT/sysctl/10-map-count.conf" /etc/sysctl.d/10-map-count.conf

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
else
  # Magic SysRq is home-only: the edge has no attached keyboard, and its stock image
  # ships a narrower kernel.sysrq=176 that we deliberately do not override.
  install -m 0644 "$ROOT/sysctl/21-sysrq-console.conf" /etc/sysctl.d/21-sysrq-console.conf
fi

sysctl --system >/dev/null

# ---------- OOM sysctl re-assert (the kubelet overwrites vm.panic_on_oom) ----------
# The line above applies 20-oom-resilience.conf correctly. k3s then starts and the
# kubelet enforces its own expected kernel values — including vm.panic_on_oom=0 —
# silently, because --protect-kernel-defaults is not set. See NODE-HARDENING.md.
echo "==> installing OOM sysctl re-assert timer"
install -m 0644 "$ROOT/systemd/oom-resilience-reassert.service" /etc/systemd/system/oom-resilience-reassert.service
install -m 0644 "$ROOT/systemd/oom-resilience-reassert.timer" /etc/systemd/system/oom-resilience-reassert.timer
systemctl daemon-reload
systemctl enable --now oom-resilience-reassert.timer
# Apply once right now so a re-run of this script leaves the node protected without
# waiting for the timer. Harmless if k3s is not installed yet.
systemctl start oom-resilience-reassert.service || true

# ---------- kernel modules ----------

echo "==> installing kernel module loaders"
install -m 0644 "$ROOT/modules-load/k3s-calico.conf" /etc/modules-load.d/k3s-calico.conf
if [[ "$ROLE" == "home" ]]; then
  install -m 0644 "$ROOT/modules-load/k8s.conf" /etc/modules-load.d/k8s.conf
fi

for m in br_netfilter vxlan overlay; do
  modprobe "$m" 2>/dev/null || true
done

# ---------- hardware watchdog + unattended-upgrade reboot policy ----------
# Added 2026-07-18 after wk-1 hung with no panic and stayed down ~96 minutes: nothing on the
# box could reset it, and nothing brings a bare-metal mini PC back on its own.
echo "==> installing hardware watchdog + disabling unattended reboot (kured owns reboots)"
install -m 0644 "$ROOT/modules-load/watchdog.conf" /etc/modules-load.d/watchdog.conf
mkdir -p /etc/systemd/system.conf.d
install -m 0644 "$ROOT/systemd/10-watchdog.conf" /etc/systemd/system.conf.d/10-watchdog.conf

# unattended-upgrades never reboots the node itself: kured (deploy/platform/kured) drains and
# reboots the worker nodes when /var/run/reboot-required appears. See the file for why.
install -m 0644 "$ROOT/apt/52unattended-upgrades-reboot" /etc/apt/apt.conf.d/52unattended-upgrades-reboot

# Arm it now rather than waiting for the next boot. A board whose firmware locks the TCO off
# reports "unable to reset NO_REBOOT flag" here and simply gets no /dev/watchdog — see the
# comments in systemd/10-watchdog.conf before reaching for softdog.
modprobe iTCO_wdt 2>/dev/null || true
systemctl daemon-reexec
if [[ -e /dev/watchdog ]]; then
  echo "    hardware watchdog active ($(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null))"
else
  echo "    WARNING: no /dev/watchdog — TCO disabled in this board's BIOS; node has no self-reset"
fi

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

# The edge node's public allowlist is nftables, not iptables, and comes in two
# tables that must BOTH be present:
#
#   inet edgeguard       priority -200   /etc/nftables.d/edgeguard.nft
#                                        loaded by the stock nftables.service
#   inet edge_guardrail  priority  -50   /usr/local/sbin/edge-guardrail.sh
#                                        loaded by edge-guardrail.service
#
# edgeguard runs first and is the ONLY place the operator SSH allowlist is
# enforced -- edge_guardrail accepts `tcp dport 22` on eth0 from anywhere by
# design. If edgeguard is missing, public SSH is wide open.
#
# The admin IP is read from /etc/edge-allowlist.env and rendered into a
# generated defines file that is never committed. /etc/nftables.conf globs
# /etc/nftables.d/*.nft in alphabetical order, so 00-edge-allowlist.nft is
# parsed before edgeguard.nft and the define is in scope.
# A single-host CIDR, e.g. 203.0.113.7/32. Anything else must never reach
# edgeguard.nft: nft would fail to parse /etc/nftables.conf and nftables.service
# would then load NOTHING from /etc/nftables.d/, at this run and at every boot.
valid_host_cidr() {
  local v="$1" ip o
  [[ "$v" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/32$ ]] || return 1
  ip="${BASH_REMATCH[1]}"
  for o in ${ip//./ }; do
    (( 10#$o <= 255 )) || return 1
  done
  return 0
}

EDGEGUARD_SKIPPED=0

install_edge_nftables() {
  local env_file="/etc/edge-allowlist.env"
  local defines="/etc/nftables.d/00-edge-allowlist.nft"
  local admin_ip=""

  if [[ -f "$env_file" ]]; then
    admin_ip="$(awk -F'=' \
      '/^[[:space:]]*ADMIN_SSH_ALLOW_IP[[:space:]]*=/ {
         sub(/^[[:space:]]*/, "", $2); sub(/[[:space:]]*$/, "", $2)
         print $2; exit
       }' "$env_file")"
  fi

  # Validate BEFORE installing anything. Bailing halfway would leave
  # /etc/nftables.conf globbing an edgeguard.nft whose $ADMIN_SSH_ALLOW_IP is
  # undefined -- a parse error that takes every other table down with it. On a
  # bad value we install nothing and leave the node exactly as we found it,
  # including any allowlist a previous good run already put in place.
  if ! valid_host_cidr "$admin_ip"; then
    EDGEGUARD_SKIPPED=1
    echo "    !! ADMIN_SSH_ALLOW_IP in $env_file is '${admin_ip:-<unset>}'"
    echo "    !! expected a single IPv4 host CIDR, e.g. 203.0.113.7/32"
    case "$admin_ip" in
      *:*) echo "    !! That looks like an IPv6 address. The edgeguard rule is an IPv4"
           echo "    !! \`ip saddr\` match, so a v6 address cannot work here. Plain"
           echo "    !! \`curl ifconfig.me\` returns IPv6 on a dual-stack link -- use"
           echo "    !! \`curl -4 -fsS https://ifconfig.me\` to get the v4 address." ;;
    esac
    echo "    !! SKIPPING the edgeguard allowlist -- nothing installed, nothing changed."
    if [[ -f "$defines" ]] && valid_host_cidr "$(awk '{print $NF}' "$defines" 2>/dev/null | tail -1)"; then
      echo "    !! The allowlist from a previous run is still in place and still active."
    else
      echo "    !! PUBLIC SSH ON THIS NODE IS OPEN TO THE INTERNET. edge_guardrail"
      echo "    !! accepts tcp/22 on eth0 from any source by design; only edgeguard"
      echo "    !! restricts it. Fix $env_file and re-run this script."
    fi
    echo "    !! Verify either way with DR gate L5-D (deploy/dr/gates.md)."
    # edge_guardrail is independent of the admin IP, so still install it.
    install_firewall_unit "edge-guardrail.sh" "edge-guardrail.service"
    return 0
  fi

  install -d -m 0755 /etc/nftables.d
  install -m 0644 "$ROOT/firewall/nftables.conf" /etc/nftables.conf
  install -m 0644 "$ROOT/firewall/edgeguard.nft" /etc/nftables.d/edgeguard.nft

  printf '# Generated by prepare-host.sh from %s. Do not edit. Do not commit.\ndefine ADMIN_SSH_ALLOW_IP = %s\n' \
    "$env_file" "$admin_ip" > "$defines"
  chmod 0644 "$defines"

  systemctl enable nftables.service

  # Apply with `nft -f`, NOT `systemctl restart nftables.service`: that unit's
  # ExecStop is `nft flush ruleset`, which would also destroy Calico's tables
  # on a node that is already running K3s.
  nft -f /etc/nftables.conf

  # edge_guardrail: the -50 defence-in-depth table. Idempotent -- the script
  # deletes and recreates only its own table.
  install_firewall_unit "edge-guardrail.sh" "edge-guardrail.service"
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
      echo "    EDIT IT NOW and set ADMIN_SSH_ALLOW_IP, then re-run this script."
    fi
    echo "==> edge nftables allowlist (edgeguard + edge_guardrail)"
    install_edge_nftables
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
         net.ipv4.conf.wg0.rp_filter \
         vm.panic_on_oom kernel.panic kernel.panic_on_oops ; do
  v="$(sysctl -n "$k" 2>/dev/null || echo '?')"
  printf '[sysctl] %-40s = %s\n' "$k" "$v"
done

# vm.panic_on_oom is the one value the kubelet actively fights (see
# sysctl/20-oom-resilience.conf). Call it out instead of leaving the operator to
# spot a 0 in the list above.
if [[ "$(sysctl -n vm.panic_on_oom 2>/dev/null)" == "1" ]]; then
  echo "[oom-self-heal] ON  (good: node-wide OOM panics and reboots in $(sysctl -n kernel.panic)s)"
else
  echo "[oom-self-heal] OFF (kubelet has reset vm.panic_on_oom to 0;"
  echo "                 oom-resilience-reassert.timer restores it within 5 min)"
fi
echo "[reassert]   oom-resilience-reassert.timer: $(systemctl is-active oom-resilience-reassert.timer 2>/dev/null)"

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

if [[ "$ROLE" == "edge" ]]; then
  for t in edgeguard edge_guardrail; do
    if nft list table inet "$t" >/dev/null 2>&1; then
      echo "[nft] inet $t present"
    else
      echo "[nft] inet $t MISSING (public allowlist is not enforced)"
    fi
  done
  ssh_rule="$(nft list table inet edgeguard 2>/dev/null | grep -c 'tcp dport 22 accept' || true)"
  if [[ "$ssh_rule" == "0" ]]; then
    echo "[nft] edgeguard has NO SSH allowlist rule -- port 22 is open to the internet"
  else
    echo "[nft] edgeguard SSH allowlist rule present ($ssh_rule)"
  fi
fi

if [[ "${EDGEGUARD_SKIPPED:-0}" == "1" ]]; then
  echo
  echo "!! edgeguard allowlist was SKIPPED -- see the ADMIN_SSH_ALLOW_IP warning above."
  echo "!! Set it in /etc/edge-allowlist.env and re-run this script before leaving Layer 0."
fi

echo
echo "==> done. Next: bootstrap WireGuard. See ../wireguard/README.md"
