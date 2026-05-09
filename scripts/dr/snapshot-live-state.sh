#!/usr/bin/env bash
# Emit a markdown fragment with the live cluster state, suitable for pasting
# into k8s-cluster/dr/SNAPSHOT-YYYY-MM-DD.md.
#
# Captures: per-node OS/kernel/sysctl/swap/modules/firewall facts, K3s and
# Calico versions, Helm chart versions for cert-manager, image+digest pairs
# for every Deployment/StatefulSet/DaemonSet, ArgoCD Application revisions,
# ClusterIssuer state, persistent volumes.
#
# Read-only. Does not modify the cluster.
#
# Usage:
#   scripts/dr/snapshot-live-state.sh > /tmp/snapshot.md
set -euo pipefail

if ! command -v ssh >/dev/null; then
  echo "ssh is required" >&2
  exit 1
fi

ssh_ms1() { ssh -o BatchMode=yes -o ConnectTimeout=8 ms-1 "$@"; }
kubectl_ms1() { ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $*"; }

today_utc="$(date -u +%Y-%m-%d)"
repo_sha="$(git -C "$(dirname "$0")/../.." rev-parse HEAD 2>/dev/null || echo unknown)"

cat <<EOF
# Cluster snapshot -- ${today_utc}

## Capture metadata

| Field | Value |
|---|---|
| Snapshot date (UTC) | ${today_utc} |
| Repo Git revision | \`${repo_sha}\` |
| Capture method | live SSH + kubectl |

EOF

# ---------- nodes ----------

echo "## Nodes"
echo
kubectl_ms1 "get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\"|\"}{.status.nodeInfo.kernelVersion}{\"|\"}{.status.nodeInfo.osImage}{\"|\"}{.status.nodeInfo.kubeletVersion}{\"\\n\"}{end}'" | \
  awk -F'|' 'BEGIN{print "| Hostname | Kernel | OS | Kubelet |"; print "|---|---|---|---|"} {printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4}'
echo

# ---------- per-node host facts ----------

echo "## Host facts"
echo
echo "| Fact | ms-1 | wk-1 | wk-2 | ctb-edge-1 |"
echo "|---|---|---|---|---|"

# helper: query a sysctl on each node and emit a row
sysctl_row() {
  local key="$1"
  local label="$2"
  local v_ms1 v_wk1 v_wk2 v_edge
  v_ms1="$(ssh -J vm-1 -o BatchMode=yes -o ConnectTimeout=8 root@172.27.15.12 "sysctl -n $key 2>/dev/null" || echo "?")"
  v_wk1="$(ssh -J vm-1 -o BatchMode=yes -o ConnectTimeout=8 root@172.27.15.11 "sysctl -n $key 2>/dev/null" || echo "?")"
  v_wk2="$(ssh -J vm-1 -o BatchMode=yes -o ConnectTimeout=8 root@172.27.15.13 "sysctl -n $key 2>/dev/null" || echo "?")"
  v_edge="$(ssh -o BatchMode=yes -o ConnectTimeout=8 vm-1 "sysctl -n $key 2>/dev/null" || echo "?")"
  echo "| ${label} | ${v_ms1} | ${v_wk1} | ${v_wk2} | ${v_edge} |"
}

sysctl_row net.ipv4.ip_forward "ip_forward"
sysctl_row net.ipv4.conf.all.rp_filter "rp_filter (all)"
sysctl_row net.ipv4.conf.wg0.rp_filter "rp_filter (wg0)"
sysctl_row net.bridge.bridge-nf-call-iptables "bridge-nf-call-iptables"

# swap state per node
swap_row() {
  local label="$1"
  local v_ms1 v_wk1 v_wk2 v_edge
  v_ms1="$(ssh -J vm-1 -o BatchMode=yes -o ConnectTimeout=8 root@172.27.15.12 "swapon --show=NAME --noheadings 2>/dev/null | head -1" || echo "")"
  v_wk1="$(ssh -J vm-1 -o BatchMode=yes -o ConnectTimeout=8 root@172.27.15.11 "swapon --show=NAME --noheadings 2>/dev/null | head -1" || echo "")"
  v_wk2="$(ssh -J vm-1 -o BatchMode=yes -o ConnectTimeout=8 root@172.27.15.13 "swapon --show=NAME --noheadings 2>/dev/null | head -1" || echo "")"
  v_edge="$(ssh -o BatchMode=yes -o ConnectTimeout=8 vm-1 "swapon --show=NAME --noheadings 2>/dev/null | head -1" || echo "")"
  fmt() { [[ -z "$1" ]] && echo "OFF" || echo "ON ($1)"; }
  echo "| ${label} | $(fmt "$v_ms1") | $(fmt "$v_wk1") | $(fmt "$v_wk2") | $(fmt "$v_edge") |"
}

swap_row "swap"
echo

# ---------- platform versions ----------

echo "## Platform versions"
echo
echo "| Component | Version |"
echo "|---|---|"

k3s_v="$(kubectl_ms1 "get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'")"
echo "| K3s / kubelet | ${k3s_v} |"

# Helm chart versions (cert-manager, etc.)
helm_releases="$(ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm list -A -o json 2>/dev/null" || echo "[]")"
echo "${helm_releases}" | jq -r '.[] | "| Helm: \(.name) (\(.namespace)) | \(.chart) (app: \(.app_version)) |"' 2>/dev/null || true
echo

# ---------- workload images and digests ----------

echo "## Workload images and digests"
echo
echo "| Namespace | Workload | Image | Digest |"
echo "|---|---|---|---|"

kubectl_ms1 "get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{\"|\"}{.metadata.name}{\"|\"}{range .status.containerStatuses[*]}{.image}{\";\"}{.imageID}{\";\"}{end}{\"\\n\"}{end}'" | \
  awk -F'|' '
{
  split($3, parts, ";");
  for (i = 1; i <= length(parts); i += 2) {
    if (parts[i] == "") continue;
    img = parts[i];
    digest = parts[i+1];
    sub(".*@", "", digest);
    if (digest == "") digest = "(no digest)";
    printf "| %s | %s | `%s` | `%s` |\n", $1, $2, img, digest;
  }
}'
echo

# ---------- argocd applications ----------

echo "## Argo CD Applications"
echo
echo "| Application | Path | Tracked branch | Synced commit |"
echo "|---|---|---|---|"
kubectl_ms1 "get application -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{\"|\"}{.spec.source.path}{\"|\"}{.spec.source.targetRevision}{\"|\"}{.status.sync.revision}{\"\\n\"}{end}'" | \
  awk -F'|' '{printf "| %s | `%s` | %s | `%s` |\n", $1, $2, $3, $4}'
echo

# ---------- ClusterIssuers ----------

echo "## ClusterIssuers"
echo
echo "| Name | ACME server | Status |"
echo "|---|---|---|"
kubectl_ms1 "get clusterissuer -o jsonpath='{range .items[*]}{.metadata.name}{\"|\"}{.spec.acme.server}{\"|\"}{.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}{end}'" | \
  awk -F'|' '{printf "| %s | `%s` | %s |\n", $1, $2, $3}'
echo

# ---------- PVs ----------

echo "## Persistent volumes"
echo
echo "| Claim | Size | StorageClass |"
echo "|---|---|---|"
kubectl_ms1 "get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{\"|\"}{.status.capacity.storage}{\"|\"}{.spec.storageClassName}{\"\\n\"}{end}'" | \
  awk -F'|' '{printf "| %s | %s | %s |\n", $1, $2, $3}'

echo
echo "---"
echo "Generated by \`scripts/dr/snapshot-live-state.sh\` on ${today_utc}."
