#!/usr/bin/env bash
# Installs or upgrades Argo CD from the pinned kustomization next to this script (upstream
# manifest at one exact tag + this cluster's patches). Run on ms-1. Safe to re-run: an upgrade
# is a tag bump in kustomization.yaml followed by this script.
set -euo pipefail

: "${KUBECONFIG:=/etc/rancher/k3s/k3s.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export KUBECONFIG

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Server-side apply: the Argo CD CRDs are too large for client-side apply's
# last-applied-configuration annotation. --force-conflicts takes over fields that older
# `kubectl patch` / `kubectl edit` calls own.
kubectl apply --server-side --force-conflicts -k "${SCRIPT_DIR}"

for d in argocd-redis argocd-repo-server argocd-server argocd-dex-server \
         argocd-applicationset-controller argocd-notifications-controller; do
  kubectl -n argocd rollout status "deployment/${d}" --timeout=300s
done
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
