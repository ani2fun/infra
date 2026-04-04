#!/usr/bin/env bash
set -euo pipefail

export INSTALL_K3S_VERSION="${INSTALL_K3S_VERSION:-v1.35.1+k3s1}"

curl -sfL https://get.k3s.io | \
  K3S_KUBECONFIG_MODE="644" \
  INSTALL_K3S_EXEC="server \
    --node-ip=172.27.15.12 \
    --advertise-address=172.27.15.12 \
    --tls-san=172.27.15.12 \
    --flannel-backend=none \
    --disable-network-policy \
    --disable=traefik \
    --disable=servicelb \
    --resolv-conf=/etc/rancher/k3s/k3s-resolv.conf \
    --cluster-cidr=10.42.0.0/16 \
    --service-cidr=10.43.0.0/16 \
    --node-label homelab.kakde.eu/role=server" \
  sh -

