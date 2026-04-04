#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:=/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

helm repo add jetstack https://charts.jetstack.io
helm repo update

kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true

