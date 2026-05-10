#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:=/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

# Pin the cert-manager chart so a fresh install converges to the same version
# the snapshot was captured at. Override with CERT_MANAGER_VERSION if you need
# to upgrade. Source of truth: deploy/dr/SNAPSHOT.md.
: "${CERT_MANAGER_VERSION:=v1.19.1}"

helm repo add jetstack https://charts.jetstack.io
helm repo update

kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version "${CERT_MANAGER_VERSION}" \
  --set installCRDs=true
