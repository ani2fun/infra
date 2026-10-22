# Argo CD

This folder reconstructs the documented Argo CD setup:

- install into namespace `argocd`
- pin workloads to `wk-2` through `workload=argocd`
- disable internal TLS on `argocd-server`
- expose the UI at `https://argocd.kakde.eu` through standard Kubernetes `Ingress`
- keep codefolio, synapse, synapse-go-judge, synapse-tts, bytebase and monitoring as `Application` resources pointing at this repo
- manage those `Application` resources from git too: the `applications` root (`applications/root.yaml`) syncs the `applications/` folder (non-recursive, no prune), so adding an app is a push. `configure-argocd.sh` applies the folder once on a fresh cluster, which creates the root; from then on the root owns it

## Current limitation

The live Argo CD install manifest and current controller configuration could not be exported in this session. `install-argocd.sh` follows the documented bootstrap path instead of a live manifest export.

