#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:=/etc/rancher/k3s/k3s.yaml}"
: "${EDGE_NODE:=ctb-edge-1}"
export KUBECONFIG

kubectl label node "${EDGE_NODE}" kakde.eu/edge=true --overwrite
kubectl taint node "${EDGE_NODE}" homelab.kakde.eu/edge- 2>/dev/null || true
kubectl taint node "${EDGE_NODE}" kakde.eu/edge=true:NoSchedule --overwrite

