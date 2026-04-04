#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:=/etc/rancher/k3s/k3s.yaml}"
: "${ARGOCD_NODE:=wk-2}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export KUBECONFIG

kubectl label node "${ARGOCD_NODE}" workload=argocd --overwrite

kubectl -n argocd patch deployment argocd-applicationset-controller --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"argocd"}}}}}'
kubectl -n argocd patch deployment argocd-dex-server --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"argocd"}}}}}'
kubectl -n argocd patch deployment argocd-notifications-controller --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"argocd"}}}}}'
kubectl -n argocd patch deployment argocd-redis --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"argocd"}}}}}'
kubectl -n argocd patch deployment argocd-repo-server --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"argocd"}}}}}'
kubectl -n argocd patch deployment argocd-server --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"argocd"}}}}}'
kubectl -n argocd patch statefulset argocd-application-controller --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"argocd"}}}}}'

kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server

kubectl apply -f "${SCRIPT_DIR}/argocd-ingress.yaml"
kubectl apply -f "${SCRIPT_DIR}/applications"

