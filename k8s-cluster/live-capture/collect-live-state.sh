#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$ROOT/output/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"/{cluster,hosts}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required binary: $1" >&2
    exit 1
  }
}

require_bin ssh

ssh_run() {
  local host="$1"
  shift
  case "$host" in
    ms-1)
      ssh -J vm-1 -o BatchMode=yes -o ConnectTimeout=8 root@172.27.15.12 "$*"
      ;;
    wk-1)
      ssh -J vm-1 -o BatchMode=yes -o ConnectTimeout=8 root@172.27.15.11 "$*"
      ;;
    wk-2)
      ssh -J vm-1 -o BatchMode=yes -o ConnectTimeout=8 root@172.27.15.13 "$*"
      ;;
    vm-1)
      ssh -o BatchMode=yes -o ConnectTimeout=8 vm-1 "$*"
      ;;
    *)
      ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" "$*"
      ;;
  esac
}

run_ms1() {
  ssh_run ms-1 "set -euo pipefail; export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; $*"
}

dump_host() {
  local host="$1"
  local host_dir="$OUT_DIR/hosts/$host"
  mkdir -p "$host_dir"

  ssh_run "$host" '
set -euo pipefail
echo "### hostname"
hostnamectl 2>/dev/null || hostname
echo "### os-release"
. /etc/os-release; echo "$PRETTY_NAME"
echo "### kernel"
uname -r
echo "### timedatectl"
timedatectl 2>/dev/null || true
echo "### swap"
swapon --show 2>/dev/null || echo "(no swap)"
echo "### lsmod-k8s"
lsmod | awk "{print \$1}" | grep -E "^(wireguard|br_netfilter|vxlan|overlay|nf_conntrack|ip_vs)$" | sort -u || true
echo "### sysctl-k8s"
for k in net.ipv4.ip_forward net.ipv6.conf.all.forwarding \
         net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables \
         net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter \
         net.ipv4.conf.wg0.rp_filter ; do
  printf "%s = %s\n" "$k" "$(sysctl -n "$k" 2>/dev/null || echo "?")"
done
echo "### apt-manual"
apt-mark showmanual 2>/dev/null | sort
echo "### sshd-effective"
sshd -T 2>/dev/null | grep -E "^(permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|port)\b" || true
echo "### custom-firewall-services"
for svc in homelab-fw-ms1.service homelab-fw-edge.service \
           k3s-api-lockdown.service k3s-api-lockdown-allow-cluster.service \
           edge-guardrail.service ; do
  if systemctl cat "$svc" >/dev/null 2>&1; then
    state="$(systemctl is-enabled "$svc" 2>/dev/null || echo unknown)"
    active="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
    printf "%-44s enabled=%-10s active=%s\n" "$svc" "$state" "$active"
  fi
done
echo "### ip-br"
ip -br address
echo "### routes"
ip route show table all
echo "### rules"
ip rule show
echo "### wg"
wg show 2>/dev/null || true
echo "### wg0.conf"
if [ -f /etc/wireguard/wg0.conf ]; then
  awk '\''/^PrivateKey *=/{print "PrivateKey = <redacted>"; next} {print}'\'' /etc/wireguard/wg0.conf
fi
echo "### k3s-resolv"
if [ -f /etc/rancher/k3s/k3s-resolv.conf ]; then
  cat /etc/rancher/k3s/k3s-resolv.conf
fi
echo "### systemd k3s"
systemctl cat k3s.service 2>/dev/null || true
echo "### systemd k3s-agent"
systemctl cat k3s-agent.service 2>/dev/null || true
echo "### systemd edge-guardrail"
systemctl cat edge-guardrail.service 2>/dev/null || true
echo "### nft"
nft list ruleset 2>/dev/null || true
echo "### iptables"
iptables-save 2>/dev/null || true
' > "$host_dir/host.txt"
}

dump_namespace() {
  local namespace="$1"
  local ns_dir="$OUT_DIR/cluster/namespaces/$namespace"
  mkdir -p "$ns_dir"

  run_ms1 "kubectl get namespace $namespace -o yaml --show-managed-fields=false" > "$ns_dir/namespace.yaml" || true
  run_ms1 "kubectl -n $namespace get all,ingress,configmap,pvc,networkpolicy,serviceaccount,role,rolebinding -o yaml --show-managed-fields=false" > "$ns_dir/resources.yaml" || true
  run_ms1 "kubectl -n $namespace get secret -o custom-columns=NAME:.metadata.name,TYPE:.type --no-headers" > "$ns_dir/secrets-metadata.txt" || true
}

echo "capturing cluster state into $OUT_DIR"

run_ms1 "kubectl get nodes -o wide" > "$OUT_DIR/cluster/nodes.txt"
run_ms1 "kubectl get nodes -o yaml --show-managed-fields=false" > "$OUT_DIR/cluster/nodes.yaml"
run_ms1 "kubectl get ns --show-labels" > "$OUT_DIR/cluster/namespaces.txt"
run_ms1 "kubectl get ns -o yaml --show-managed-fields=false" > "$OUT_DIR/cluster/namespaces.yaml"
run_ms1 "kubectl get ingressclass,storageclass,pv -o yaml --show-managed-fields=false" > "$OUT_DIR/cluster/cluster-scoped.yaml" || true
run_ms1 "kubectl get applications.argoproj.io -A -o yaml --show-managed-fields=false" > "$OUT_DIR/cluster/argocd-applications.yaml" || true
run_ms1 "kubectl get clusterissuer,certificate,certificaterequest,order,challenge -A -o yaml --show-managed-fields=false" > "$OUT_DIR/cluster/cert-manager.yaml" || true

for namespace in argocd apps-prod apps-dev databases-prod cert-manager traefik; do
  dump_namespace "$namespace"
done

KEYCLOAK_NAMESPACES="$(run_ms1 "kubectl get deploy,statefulset -A -o jsonpath='{range .items[*]}{.metadata.namespace}{\" \"}{.metadata.name}{\"\\n\"}{end}' | grep -i keycloak | awk '{print \$1}' | sort -u" || true)"
printf '%s\n' "$KEYCLOAK_NAMESPACES" > "$OUT_DIR/cluster/keycloak-namespaces.txt"
for namespace in $KEYCLOAK_NAMESPACES; do
  dump_namespace "$namespace"
done

for host in ms-1 vm-1 wk-1 wk-2; do
  dump_host "$host"
done

echo "done"
