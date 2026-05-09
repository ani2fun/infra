#!/usr/bin/env bash
# Restore the Sealed-Secrets master key on a freshly-installed cluster.
# Run AFTER the controller is installed but BEFORE applying any committed
# SealedSecret. The script:
#   1. Validates the backup file.
#   2. Scales the controller to 0.
#   3. Applies the backup secret(s).
#   4. Scales the controller back up.
#   5. Prints the new active cert digest so you can compare against
#      k8s-cluster/dr/SNAPSHOT.md.
#
# Usage:
#   scripts/dr/sealed-secrets-key-restore.sh /path/to/sealed-secrets-master-key-*.yaml
set -euo pipefail

BACKUP="${1:?usage: $0 <backup-yaml>}"

if [[ ! -f "$BACKUP" ]]; then
  echo "backup file not found: $BACKUP" >&2
  exit 1
fi

if ! grep -q "kind: List" "$BACKUP" && ! grep -q "kind: Secret" "$BACKUP"; then
  echo "backup file does not look like a Kubernetes secret: $BACKUP" >&2
  exit 1
fi

if ! grep -q "sealedsecrets.bitnami.com/sealed-secrets-key" "$BACKUP"; then
  echo "backup file is missing the sealed-secrets-key label" >&2
  exit 1
fi

echo "==> verifying backup file"
echo "    sha256: $(shasum -a 256 "$BACKUP" | awk '{print $1}')"
echo "    keys:   $(grep -c '^  name:' "$BACKUP" || true)"

echo
echo "==> staging backup on ms-1"
remote_path="/tmp/sealed-secrets-restore-$$.yaml"
scp -o BatchMode=yes "$BACKUP" "ms-1:${remote_path}"

ssh_ms1() { ssh -o BatchMode=yes -o ConnectTimeout=8 ms-1 "$@"; }

cleanup() {
  ssh_ms1 "rm -f ${remote_path}" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> scaling sealed-secrets-controller to 0"
ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system scale deployment sealed-secrets-controller --replicas=0"
ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system rollout status deployment sealed-secrets-controller --timeout=60s" || true

echo "==> applying backup"
ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl apply -f ${remote_path}"

echo "==> scaling sealed-secrets-controller back to 1"
ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system scale deployment sealed-secrets-controller --replicas=1"
ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system rollout status deployment sealed-secrets-controller --timeout=120s"

echo
echo "==> verification: active cert digest"
cert="$(ssh_ms1 "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o jsonpath='{.items[0].data.tls\.crt}'" | base64 -d)"
digest="$(echo "$cert" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | awk -F= '{print $2}')"
echo "    sha256 fingerprint of active cert: ${digest}"

cat <<EOF

==> restore complete

Compare the fingerprint above against the value recorded in
k8s-cluster/dr/SNAPSHOT.md (or your password-manager record).

If they match, every committed SealedSecret will decrypt cleanly when
applied. You can now proceed to layer 5 of the runbook (Traefik).
EOF
