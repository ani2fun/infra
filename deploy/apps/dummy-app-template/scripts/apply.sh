#!/usr/bin/env bash
set -euo pipefail

echo "=== APPLY DEV ==="
kubectl apply -k overlays/dev

echo
echo "=== APPLY PROD ==="
kubectl apply -k overlays/prod

echo
echo "=== ROLLOUT STATUS ==="
kubectl -n apps-dev rollout status deployment/dummy-app-template --timeout=180s
kubectl -n apps-prod rollout status deployment/dummy-app-template --timeout=180s