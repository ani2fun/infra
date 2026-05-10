#!/usr/bin/env bash
set -euo pipefail

: "${KUBECONFIG:=/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

kubectl -n traefik patch deploy traefik --type='json' -p='[
  {
    "op":"add",
    "path":"/spec/template/spec/containers/0/securityContext",
    "value":{
      "allowPrivilegeEscalation":false,
      "readOnlyRootFilesystem":false,
      "capabilities":{
        "drop":["ALL"],
        "add":["NET_BIND_SERVICE"]
      }
    }
  }
]'

kubectl -n traefik patch deploy traefik --type='merge' -p '{
  "spec": {
    "strategy": {
      "type": "RollingUpdate",
      "rollingUpdate": {
        "maxSurge": 0,
        "maxUnavailable": 1
      }
    }
  }
}'

kubectl -n traefik patch deploy traefik --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe","value":{
    "tcpSocket":{"port":80},
    "initialDelaySeconds":10,
    "periodSeconds":10,
    "failureThreshold":6
  }},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe","value":{
    "tcpSocket":{"port":80},
    "initialDelaySeconds":3,
    "periodSeconds":5,
    "failureThreshold":6
  }}
]'

kubectl -n traefik rollout restart deploy traefik
kubectl -n traefik rollout status deploy traefik

