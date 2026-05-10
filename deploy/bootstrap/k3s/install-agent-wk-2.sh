#!/usr/bin/env bash
set -euo pipefail

: "${K3S_TOKEN:?set K3S_TOKEN from ms-1 /var/lib/rancher/k3s/server/node-token}"
export INSTALL_K3S_VERSION="${INSTALL_K3S_VERSION:-v1.35.1+k3s1}"

curl -sfL https://get.k3s.io | \
  K3S_URL="${K3S_URL:-https://172.27.15.12:6443}" \
  K3S_TOKEN="${K3S_TOKEN}" \
  INSTALL_K3S_EXEC="agent \
    --node-ip=172.27.15.13 \
    --resolv-conf=/etc/rancher/k3s/k3s-resolv.conf \
    --node-label homelab.kakde.eu/role=worker" \
  sh -

