#!/usr/bin/env bash
set -euo pipefail

sudo mkdir -p /etc/rancher/k3s
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/rancher/k3s/k3s-resolv.conf

readlink -f /etc/rancher/k3s/k3s-resolv.conf
grep -E '^(nameserver|search|options)' /etc/rancher/k3s/k3s-resolv.conf

