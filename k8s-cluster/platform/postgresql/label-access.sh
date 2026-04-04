#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:=/etc/rancher/k3s/k3s.yaml}"
: "${POSTGRES_NODE:=wk-1}"
export KUBECONFIG

kubectl label node "${POSTGRES_NODE}" kakde.eu/postgresql=true --overwrite
kubectl label namespace apps-prod kakde.eu/postgresql-access=true --overwrite

