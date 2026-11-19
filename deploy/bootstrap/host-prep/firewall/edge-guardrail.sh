#!/usr/bin/env bash
set -euo pipefail

PUB_IF="${PUB_IF:-eth0}"

if nft list table inet edge_guardrail >/dev/null 2>&1; then
  nft delete table inet edge_guardrail
fi

nft -f - <<NFT
add table inet edge_guardrail
add chain inet edge_guardrail input { type filter hook input priority -50; policy drop; }

add rule inet edge_guardrail input iifname "lo" accept
add rule inet edge_guardrail input ct state established,related accept
add rule inet edge_guardrail input iifname != "$PUB_IF" accept

add rule inet edge_guardrail input iifname "$PUB_IF" ip protocol icmp accept
add rule inet edge_guardrail input iifname "$PUB_IF" ip6 nexthdr icmpv6 accept
add rule inet edge_guardrail input iifname "$PUB_IF" udp dport 51820 accept
add rule inet edge_guardrail input iifname "$PUB_IF" tcp dport 22 accept
add rule inet edge_guardrail input iifname "$PUB_IF" tcp dport { 80, 443 } accept
add rule inet edge_guardrail input iifname "$PUB_IF" counter drop
NFT

