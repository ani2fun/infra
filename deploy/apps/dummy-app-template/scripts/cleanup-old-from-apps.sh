#!/usr/bin/env bash
set -euo pipefail

APP_NAME="dummy-app-template"

kubectl -n apps delete ingress "${APP_NAME}" --ignore-not-found=true
kubectl -n apps delete ingress "${APP_NAME}-ingress" --ignore-not-found=true

kubectl -n apps delete service "${APP_NAME}" --ignore-not-found=true
kubectl -n apps delete service "${APP_NAME}-dev" --ignore-not-found=true

kubectl -n apps delete deployment "${APP_NAME}" --ignore-not-found=true
kubectl -n apps delete deployment "${APP_NAME}-dev" --ignore-not-found=true

kubectl -n apps delete certificate "${APP_NAME}-kakde-eu-tls" --ignore-not-found=true
kubectl -n apps delete certificate "dev-${APP_NAME}-kakde-eu-tls" --ignore-not-found=true

kubectl -n apps delete secret "${APP_NAME}-kakde-eu-tls" --ignore-not-found=true
kubectl -n apps delete secret "dev-${APP_NAME}-kakde-eu-tls" --ignore-not-found=true

kubectl -n apps get all,ingress,certificate,secret | grep "${APP_NAME}" || echo "OK: no ${APP_NAME} resources left in apps"