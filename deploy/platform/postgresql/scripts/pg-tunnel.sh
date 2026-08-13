#!/usr/bin/env bash
set -euo pipefail

# Forwards localhost:15432 to the live postgresql-0 pod.
#
# The SSH hop MUST stay on wk-1: wk-1 hosts the pod, and the NetworkPolicy
# postgresql-allow-from-wk1-host admits wk-1's host IP (172.27.15.11) by
# ipBlock. Do not route via ms-1, and do not add a policy to make that work --
# ms-1's traffic crosses the Calico VXLAN overlay and arrives with its tunnel
# address as the inner source, which no ipBlock can usefully cover. See the
# comments in ../5-networkpolicy.yaml.
#
# Calico hands out a fresh pod IP on every reschedule, so the pod IP is looked
# up at run time. Hardcoding it turns any pod restart into a connection timeout.

# wk-1 -- load-bearing, see above. 172.27.15.11 is wk-1 on the cluster VLAN;
# from a workstation off that VLAN use SSH_HOST=wk-1 (192.168.15.3), which is
# the same host and is admitted by the same policy's second ipBlock.
: "${SSH_HOST:=root@172.27.15.11}"
: "${KUBECTL_HOST:=ms-1}"           # control-plane node used for the lookup
: "${NAMESPACE:=databases-prod}"
: "${LOCAL_PORT:=15432}"

POD_IP="$(ssh "${KUBECTL_HOST}" \
  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n ${NAMESPACE} get pod \
     -l app.kubernetes.io/name=postgresql \
     -o jsonpath='{.items[0].status.podIP}'")"

if [[ -z "${POD_IP}" ]]; then
  echo "pg-tunnel: no postgresql pod IP found in ${NAMESPACE} (asked ${KUBECTL_HOST})" >&2
  exit 1
fi

echo "pg-tunnel: localhost:${LOCAL_PORT} -> ${POD_IP}:5432 via ${SSH_HOST}" >&2
exec ssh -N -L "${LOCAL_PORT}:${POD_IP}:5432" "${SSH_HOST}"
