#!/usr/bin/env bash
# Back up the Sealed-Secrets master key from the live cluster to a local
# YAML file. Store the result in a password manager or on an encrypted USB.
# NEVER commit it to Git.
#
# Usage:
#   scripts/dr/sealed-secrets-key-backup.sh /path/to/output/dir
#
# Output: $DIR/sealed-secrets-master-key-YYYYMMDDTHHMMSSZ.yaml
set -euo pipefail

OUT_DIR="${1:?usage: $0 <output-dir>}"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
out_file="${OUT_DIR}/sealed-secrets-master-key-${ts}.yaml"

echo "==> exporting active sealed-secrets keys from kube-system"
ssh -o BatchMode=yes -o ConnectTimeout=8 ms-1 \
  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get secrets -n kube-system \
   -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
   -o yaml" > "${out_file}"

if ! grep -q "kind: List" "${out_file}" && ! grep -q "kind: Secret" "${out_file}"; then
  echo "ERROR: backup output does not look like a Kubernetes secret" >&2
  rm -f "${out_file}"
  exit 1
fi

chmod 0600 "${out_file}"

key_count="$(grep -c '^  name:' "${out_file}" || true)"
sha="$(shasum -a 256 "${out_file}" | awk '{print $1}')"

cat <<EOF

==> backup complete
file:    ${out_file}
keys:    ${key_count}
sha256:  ${sha}

NEXT STEPS:
  1. Move this file off the workstation onto an encrypted USB or into
     a password-manager attachment.
  2. Record the sha256 above in your password manager. On restore day
     you will compare against this value to confirm the file you reach
     for is the file you backed up.
  3. Do NOT commit this file. It contains the private key that decrypts
     every committed SealedSecret in this repo.

To restore on a fresh cluster, see:
  k8s-cluster/dr/sealed-secrets-key-backup.md
  scripts/dr/sealed-secrets-key-restore.sh
EOF
