#!/usr/bin/env bash
# Defence-in-depth iptables drops on vm-1's public NIC (eth0). Blocks
# Kubernetes-internal ports that should never be reachable from the internet:
#   10250/tcp   kubelet
#   4789/udp    Calico VXLAN
#   30000-32767 NodePort range (we don't use NodePorts, but block anyway)
#
# Runs alongside platform/traefik/edge-guardrail.sh, which is the strict
# nftables allowlist on eth0 and the primary defence. This script is
# secondary belt-and-braces; if edge-guardrail were ever flushed accidentally,
# these drops would still hold.
#
# Idempotent.
set -euo pipefail

# IPv4: block kubelet, VXLAN, NodePorts on PUBLIC iface only (eth0)
iptables -C INPUT -i eth0 -p tcp --dport 10250 -j DROP 2>/dev/null || iptables -I INPUT 1 -i eth0 -p tcp --dport 10250 -j DROP
iptables -C INPUT -i eth0 -p udp --dport 4789 -j DROP 2>/dev/null || iptables -I INPUT 1 -i eth0 -p udp --dport 4789 -j DROP
iptables -C INPUT -i eth0 -p tcp --dport 30000:32767 -j DROP 2>/dev/null || iptables -I INPUT 1 -i eth0 -p tcp --dport 30000:32767 -j DROP
iptables -C INPUT -i eth0 -p udp --dport 30000:32767 -j DROP 2>/dev/null || iptables -I INPUT 1 -i eth0 -p udp --dport 30000:32767 -j DROP

# IPv6: same idea (Contabo has public IPv6)
ip6tables -C INPUT -i eth0 -p tcp --dport 10250 -j DROP 2>/dev/null || ip6tables -I INPUT 1 -i eth0 -p tcp --dport 10250 -j DROP
ip6tables -C INPUT -i eth0 -p udp --dport 4789 -j DROP 2>/dev/null || ip6tables -I INPUT 1 -i eth0 -p udp --dport 4789 -j DROP
ip6tables -C INPUT -i eth0 -p tcp --dport 30000:32767 -j DROP 2>/dev/null || ip6tables -I INPUT 1 -i eth0 -p tcp --dport 30000:32767 -j DROP
ip6tables -C INPUT -i eth0 -p udp --dport 30000:32767 -j DROP 2>/dev/null || ip6tables -I INPUT 1 -i eth0 -p udp --dport 30000:32767 -j DROP
