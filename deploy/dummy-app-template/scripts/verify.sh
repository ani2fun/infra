#!/usr/bin/env bash
set -euo pipefail

echo "=== DEV OBJECTS ==="
kubectl -n apps-dev get deploy,svc,ingress,certificate,secret | grep dummy-app-template || true

echo
echo "=== PROD OBJECTS ==="
kubectl -n apps-prod get deploy,svc,ingress,certificate,secret | grep dummy-app-template || true

echo
echo "=== DEV ENDPOINTS ==="
kubectl -n apps-dev get endpoints dummy-app-template

echo
echo "=== PROD ENDPOINTS ==="
kubectl -n apps-prod get endpoints dummy-app-template

echo
echo "=== DEV INGRESS ==="
kubectl -n apps-dev get ingress dummy-app-template -o yaml

echo
echo "=== PROD INGRESS ==="
kubectl -n apps-prod get ingress dummy-app-template -o yaml