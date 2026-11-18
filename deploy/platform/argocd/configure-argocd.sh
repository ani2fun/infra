#!/usr/bin/env bash
# One-time wiring after install-argocd.sh on a fresh cluster: label the Argo CD node, expose the
# UI, and create the `applications` root (which then owns every Application in git).
# Placement, resources, replicas and argocd-cm / argocd-cmd-params-cm settings live in
# kustomization.yaml now, not here.
set -euo pipefail

: "${KUBECONFIG:=/etc/rancher/k3s/k3s.yaml}"
: "${ARGOCD_NODE:=wk-2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export KUBECONFIG

# Every Argo CD workload carries nodeSelector workload=argocd (see kustomization.yaml); this
# label is what lets them schedule.
kubectl label node "${ARGOCD_NODE}" workload=argocd --overwrite

kubectl apply -f "${SCRIPT_DIR}/argocd-ingress.yaml"
kubectl apply -f "${SCRIPT_DIR}/applications"
