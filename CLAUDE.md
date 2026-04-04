# Claude Code Prompt for This Project

You are working in `~/Development/homelab/infra`, a personal Kubernetes homelab infrastructure repository.

Your job is to help maintain, document, and evolve this repo safely. Optimize for correctness, reproducibility, and operator clarity over cleverness.

## Project Summary

This project describes a small but serious homelab platform built from:

- four Ubuntu 24.04 machines
- a WireGuard private mesh
- a K3s cluster with Calico
- one public cloud edge node for ingress
- Traefik as the only intended public web entry point
- cert-manager with Cloudflare DNS-01 for TLS
- Argo CD for GitOps
- internal PostgreSQL
- Keycloak plus app workloads such as portfolio and notebook

The design rule is simple: only the edge node should be publicly exposed. Home nodes and internal services should stay private.

## Current Architecture

- `ms-1`: K3s server and main admin host
- `wk-1`: worker intended for PostgreSQL
- `wk-2`: worker intended for Argo CD
- `vm-1` / `ctb-edge-1`: public edge worker intended for Traefik

Reference network values from the docs:

- home LAN: `192.168.15.0/24`
- WireGuard: `172.27.15.0/24`
- pod CIDR: `10.42.0.0/16`
- service CIDR: `10.43.0.0/16`

Connection to any of these nodes is possible via SSH.
~/.ssh/config is configured to use the root user on theses nodes.
you can simply run `ssh ms-1` to connect to the server ms-1 in the cluster, where current kubernetes control plane is running.

Reference public hosts include:

- `kakde.eu`
- `dev.kakde.eu`
- `notebook.kakde.eu`
- `argocd.kakde.eu`
- `keycloak.kakde.eu`
- `whoami.kakde.eu`
- `whoami-auth.kakde.eu`

## Source of Truth Rules

Follow these in order:

1. Live cluster state and current operator intent.
2. Version-controlled manifests and scripts for the current platform.
3. Main tutorial docs under `_docs/k8s-homelab/`.
4. Older historical notes and legacy layout.

Important repo nuance:

- The docs describe a newer `k8s-cluster/` layout as the preferred target architecture.
- The current working tree still contains the older `deploy/` and `argocd/` layout.
- `git status` shows the repo is in transition: many `k8s-cluster/` files are staged in git history but are not present on disk right now.
- Do not assume `k8s-cluster/` exists in the filesystem unless you verify it first.
- Treat `deploy/` as the currently available manifest tree unless the user is explicitly migrating or restoring the newer layout.

## How To Work In This Repo

- Read the repo before proposing structural changes.
- Prefer small, explicit, reviewable edits to YAML, shell scripts, and docs.
- Preserve the homelab’s teaching value: clarity matters as much as functionality.
- Prefer repeatable documented steps over one-off fixes.
- If you discover drift, improve the rebuild path or docs instead of normalizing ad hoc commands.
- Never commit real secrets, private keys, Cloudflare tokens, or production passwords.
- Keep examples sanitized and use placeholder values like `CHANGE_ME_*`.

## Deployment and Manifest Conventions

When editing or creating Kubernetes manifests:

- Keep Traefik as the ingress controller.
- Public ingress should be edge-only in intent.
- Internal services like PostgreSQL must remain private.
- Prefer `ClusterIP` services behind Traefik.
- Keep `Ingress` and `Service` in the same namespace.
- Separate environments by namespace rather than renaming core objects.
- Avoid suffixing resource names with `-dev` unless there is a very strong reason.

For app overlays, follow the established convention:

- dev namespace: `apps-dev`
- prod namespace: `apps-prod`
- dev host pattern: `dev.<app>.kakde.eu`
- prod host pattern: `<app>.kakde.eu`

Traefik ingress expectations in this repo:

- `spec.ingressClassName: traefik`
- `metadata.annotations["kubernetes.io/ingress.class"]: traefik`
- `metadata.annotations["traefik.ingress.kubernetes.io/router.tls"]: "true"`

Without the TLS router annotation, HTTPS may return a Traefik 404 in this cluster.

## Operational Priorities

Recover and troubleshoot from the bottom up:

1. WireGuard
2. K3s node health
3. Calico
4. Traefik and edge firewall guardrail
5. cert-manager and TLS
6. Argo CD
7. PostgreSQL
8. Keycloak
9. application workloads

Before major changes, favor checks like:

- `kubectl get nodes -o wide`
- `kubectl get pods -A`
- `kubectl get ingress -A`
- `kubectl get application -n argocd`
- `kubectl get certificate,challenge,order -A`

If the platform is already live, avoid changing multiple layers at once.

## Documentation Expectations

This repo is also a learning and rebuild guide for a beginner who can use shell commands and edit YAML.

When writing docs:

- explain the why, not just the commands
- prefer step-by-step rebuildable flows
- keep terminology consistent with the node names and platform roles above
- distinguish clearly between current guidance and historical notes
- call out operational limitations, especially for secrets, PostgreSQL state, and Keycloak realm state

## Safety Rules

- Do not remove or rewrite user changes unless explicitly asked.
- Be careful in a dirty git worktree.
- If a path mentioned in docs does not exist, verify whether the repo is mid-migration before “fixing” it.
- Do not invent live infrastructure state; verify with files or commands.
- Do not expose PostgreSQL publicly.
- Do not suggest bypassing the edge-only ingress model without a clear user request.

## Preferred Outputs

When asked to help, bias toward one of these:

- precise YAML or shell edits
- documentation updates aligned with the current architecture
- migration help between legacy `deploy/` layout and target `k8s-cluster/` layout
- troubleshooting steps ordered by infrastructure layer
- sanity checks that reduce drift and improve recoverability

If information is missing, say what you verified, what is inferred, and what still needs confirmation.
