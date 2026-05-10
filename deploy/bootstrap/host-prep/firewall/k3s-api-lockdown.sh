#!/usr/bin/env bash
# Builds an iptables chain that allows K3s API ports (6443, 9345) only from
# loopback and the WireGuard overlay (172.27.15.0/24), TCP-resets everything
# else.
#
# Idempotent.
set -euo pipefail

CHAIN="K3S_API_LOCKDOWN"
WG_IF="wg0"
WG_CIDR="172.27.15.0/24"

iptables -N "${CHAIN}" 2>/dev/null || true
iptables -F "${CHAIN}"

iptables -A "${CHAIN}" -i lo -j ACCEPT
iptables -A "${CHAIN}" -i "${WG_IF}" -s "${WG_CIDR}" -j ACCEPT
iptables -A "${CHAIN}" -p tcp -j REJECT --reject-with tcp-reset

if ! iptables -C INPUT -p tcp -m multiport --dports 6443,9345 -j "${CHAIN}" 2>/dev/null; then
  iptables -I INPUT 1 -p tcp -m multiport --dports 6443,9345 -j "${CHAIN}"
fi
