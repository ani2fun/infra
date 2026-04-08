# Keycloak capture gap

This directory now contains a **starter GitOps scaffold** for Keycloak, but it is not yet a confirmed export of the live cluster state.

## What still needs to be exported from the live cluster

- namespace name
- Deployment or StatefulSet manifest
- image tag and startup args
- Service and Ingress manifests
- TLS secret reference
- Secret names and external secret references
- database connection details and the PostgreSQL database or schema used by Keycloak
- any PVCs, storage classes, and backup routines
- realm export, clients, redirect URIs, and admin bootstrap method

## Scaffold added here

- `base/` contains a starting Deployment and Service
- `overlays/prod/` contains a starting Ingress and Kustomization
- `overlays/prod/github-oauth-sealedsecret.example.yaml` shows the intended GitHub OAuth secret shape

Treat these files as a draft to be reconciled against the live cluster before Argo CD points at them.

## Production GitHub OAuth secret

The current `infra` repo does not contain the live Keycloak manifests yet, so there is no committed location today for the production GitHub OAuth client secret.

When Keycloak is exported into GitOps, the GitHub broker secret should live alongside the Keycloak app manifests as a SealedSecret in the Keycloak namespace, not under `deploy/dsa-tracker/`.

Recommended shape once Keycloak manifests are captured:

- path: `k8s-cluster/apps/keycloak/overlays/prod/github-oauth-sealedsecret.yaml`
- runtime secret name: `keycloak-github-oauth`
- secret keys:
  - `client-id`
  - `client-secret`

Then the Keycloak Deployment or StatefulSet should reference that runtime secret and the realm or broker config should read those values for the GitHub identity provider.

## How this pack helps

`../../live-capture/collect-live-state.sh` is designed to discover Keycloak workloads and dump their namespace resources once SSH access is available.
