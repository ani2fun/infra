#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:=/etc/rancher/k3s/k3s.yaml}"
: "${EDGE_NODE:=ctb-edge-1}"
export KUBECONFIG

kubectl taint nodes ms-1 node-role.kubernetes.io/control-plane=true:NoSchedule --overwrite || true
kubectl taint nodes "${EDGE_NODE}" homelab.kakde.eu/edge- 2>/dev/null || true
kubectl taint nodes "${EDGE_NODE}" kakde.eu/edge=true:NoSchedule --overwrite

kubectl label node ms-1 homelab.kakde.eu/role=server --overwrite
kubectl label node wk-1 homelab.kakde.eu/role=worker --overwrite
kubectl label node wk-2 homelab.kakde.eu/role=worker --overwrite
kubectl label node "${EDGE_NODE}" homelab.kakde.eu/role=edge --overwrite
kubectl label node "${EDGE_NODE}" kakde.eu/edge=true --overwrite

kubectl get nodes --show-labels

