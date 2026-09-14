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

# All argocd workloads ship with no resource requests/limits (BestEffort QoS) unless patched here.
# These touch spec.template.spec.containers, a list keyed by container name — JSON merge patch
# (--type merge, used above for the scalar nodeSelector field) would replace the whole list and
# drop image/ports/volumeMounts. --type strategic merges by container name instead.
kubectl -n argocd patch statefulset argocd-application-controller --type strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-application-controller","resources":{"requests":{"cpu":"50m","memory":"192Mi"},"limits":{"cpu":"1000m","memory":"512Mi"}}}]}}}}'
kubectl -n argocd patch deployment argocd-repo-server --type strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-repo-server","resources":{"requests":{"cpu":"50m","memory":"128Mi"},"limits":{"cpu":"1000m","memory":"768Mi"}}}]}}}}'
kubectl -n argocd patch deployment argocd-repo-server --type merge -p '{"spec":{"replicas":2}}'
kubectl -n argocd patch deployment argocd-server --type strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-server","resources":{"requests":{"cpu":"20m","memory":"96Mi"},"limits":{"cpu":"500m","memory":"256Mi"}}}]}}}}'
kubectl -n argocd patch deployment argocd-dex-server --type strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"dex","resources":{"requests":{"cpu":"10m","memory":"64Mi"},"limits":{"cpu":"200m","memory":"192Mi"}}}]}}}}'
kubectl -n argocd patch deployment argocd-redis --type strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"redis","resources":{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}}]}}}}'
kubectl -n argocd patch deployment argocd-notifications-controller --type strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-notifications-controller","resources":{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}}]}}}}'
kubectl -n argocd patch deployment argocd-applicationset-controller --type strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"argocd-applicationset-controller","resources":{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}}]}}}}'

kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server

kubectl apply -f "${SCRIPT_DIR}/argocd-ingress.yaml"
kubectl apply -f "${SCRIPT_DIR}/applications"

