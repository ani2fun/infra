#!/usr/bin/env bash
# Host firewall for ms-1 (K3s server). Allows established + loopback + SSH,
# locks the K3s API to wg0, drops everything else on :6443.
#
# Idempotent: each rule is checked with -C before being inserted.
set -euo pipefail

# allow established/related, loopback, SSH
iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 2 -i lo -j ACCEPT
iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -p tcp --dport 22 -j ACCEPT

# allow K3s API only from wg0 overlay, drop elsewhere
iptables -C INPUT -i wg0 -s 172.27.15.0/24 -p tcp --dport 6443 -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -i wg0 -s 172.27.15.0/24 -p tcp --dport 6443 -j ACCEPT
iptables -C INPUT -p tcp --dport 6443 -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport 6443 -j DROP
