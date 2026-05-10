# Argo CD

This folder reconstructs the documented Argo CD setup:

- install into namespace `argocd`
- pin workloads to `wk-2` through `workload=argocd`
- disable internal TLS on `argocd-server`
- expose the UI at `https://argocd.kakde.eu` through standard Kubernetes `Ingress`
- keep codefolio, dsa-tracker, and piston as `Application` resources pointing at this repo

## Current limitation

The live Argo CD install manifest and current controller configuration could not be exported in this session. `install-argocd.sh` follows the documented bootstrap path instead of a live manifest export.

