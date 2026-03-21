#!/usr/bin/env bash
set -euo pipefail

echo "=== DEV RENDER ==="
kubectl kustomize overlays/dev

echo
echo "=== PROD RENDER ==="
kubectl kustomize overlays/prod