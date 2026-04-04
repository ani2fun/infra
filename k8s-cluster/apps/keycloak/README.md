# Keycloak capture gap

No Keycloak manifests, namespace definitions, or app wiring were found in the current `infra` repository, `_docs`, or nearby app repos.

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

## How this pack helps

`../../live-capture/collect-live-state.sh` is designed to discover Keycloak workloads and dump their namespace resources once SSH access is available.

