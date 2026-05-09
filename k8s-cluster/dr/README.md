# Disaster recovery pack

Everything you need to rebuild the homelab K3s cluster from cold metal back
to its current state.

## When to use this

| Situation | What to use |
|---|---|
| All four nodes wiped, fresh Ubuntu installs | Read [`RUNBOOK.md`](RUNBOOK.md) end to end. Start at Layer 0. |
| One node lost, rest healthy | Skip to the relevant layer in `RUNBOOK.md`. WireGuard layer covers single-node WG re-key; K3s layer covers single-agent re-join. |
| Database corruption, postgres pod gone | `scripts/dr/postgres-restore.sh` against the latest backup. See RUNBOOK §L8. |
| Sealed-Secrets controller key lost | [`sealed-secrets-key-backup.md`](sealed-secrets-key-backup.md). |
| Keycloak realm gone but DB intact | Reapply `apps/keycloak/`, then verify clients via the realm export JSON. See [`keycloak-realm-export.md`](keycloak-realm-export.md). |
| TLS cert lost / not renewing | cert-manager re-issues automatically once the `cloudflare-api-token` Secret is in place. See `secret-recovery.md`. |

## What you need before you start

A laptop with:

- `ssh`, `kubectl`, `helm`, `kubeseal`, `jq`, `openssl`, `curl`
- `~/.ssh/config` aliases for `ms-1`, `wk-1`, `wk-2`, `vm-1` reaching root@
- access to:
  - the password manager holding plaintext secrets (Cloudflare token,
    WireGuard private keys, postgres passwords, Keycloak admin password)
  - the off-cluster sealed-secrets master-key backup file
  - the off-cluster postgres backup tarball
  - the Cloudflare dashboard (DNS + API tokens)
  - GitHub OAuth app management (regenerate client secrets if needed)

A fresh Ubuntu 24.04.4 LTS installer image for each node.

## Pack contents

| File | Purpose |
|---|---|
| [`README.md`](README.md) | This index. |
| [`RUNBOOK.md`](RUNBOOK.md) | Step-by-step rebuild from cold OS. Layers L0–L10. |
| [`SNAPSHOT.md`](SNAPSHOT.md) | Frozen state on the day this pack was authored. Versions, image digests, host facts, Argo CD revisions. |
| [`gates.md`](gates.md) | Verification commands referenced by ID from the runbook. |
| [`secret-recovery.md`](secret-recovery.md) | Per-secret decision tree: where the plaintext comes from on rebuild day. |
| [`sealed-secrets-key-backup.md`](sealed-secrets-key-backup.md) | Backup and restore of the Sealed-Secrets controller master key. |
| [`keycloak-realm-export.md`](keycloak-realm-export.md) | Capturing and re-importing the `kakde` realm via the admin REST API. |

Companion scripts under `scripts/dr/` and `scripts/secrets/`.

## Restoration order

| Layer | What | Existing artifact | DR pack reference |
|---|---|---|---|
| L0 | Ubuntu OS prep per node | [`bootstrap/host-prep/README.md`](../bootstrap/host-prep/README.md) | `RUNBOOK.md §L0`, `gates.md§L0` |
| L1 | Router port-forwards + Cloudflare DNS | [`inventory/network.yaml`](../inventory/network.yaml) | `RUNBOOK.md §L1` |
| L2 | WireGuard mesh | [`bootstrap/wireguard/README.md`](../bootstrap/wireguard/README.md) | `RUNBOOK.md §L2`, `gates.md§L2` |
| L3 | K3s + Calico + node placement | [`bootstrap/k3s/README.md`](../bootstrap/k3s/README.md) | `RUNBOOK.md §L3`, `gates.md§L3` |
| L4 | Sealed-Secrets controller + key restore | [`platform/sealed-secrets/README.md`](../platform/sealed-secrets/README.md) | `sealed-secrets-key-backup.md` |
| L5 | Traefik + edge guardrail | [`platform/traefik/README.md`](../platform/traefik/README.md) | `gates.md§L5` |
| L6 | cert-manager + ClusterIssuers + Cloudflare token | [`platform/cert-manager/README.md`](../platform/cert-manager/README.md) | `secret-recovery.md#cloudflare-api-token` |
| L7 | Argo CD + 4 Applications | [`platform/argocd/README.md`](../platform/argocd/README.md) | `RUNBOOK.md §L7` |
| L8 | PostgreSQL StatefulSet + DB restore | [`platform/postgresql/README.md`](../platform/postgresql/README.md) | `scripts/dr/postgres-*.sh` |
| L9 | Keycloak + realm restore | [`apps/keycloak/README.md`](../apps/keycloak/README.md) | `keycloak-realm-export.md` |
| L10 | Whoami test app (and oauth2-proxy template if you want it) | [`apps/whoami/README.md`](../apps/whoami/README.md) | `RUNBOOK.md §L10` |

## What this pack cannot restore automatically

Some state lives outside Git and must be backed up separately:

| Item | Why it can't be in Git | Recovery method |
|---|---|---|
| PostgreSQL data | Binary database contents | `scripts/dr/postgres-backup.sh` / `postgres-restore.sh` |
| Keycloak realm | Stored in the postgres `keycloak` DB | Implicit from postgres restore; portable JSON via `scripts/dr/backup-keycloak-realm.sh` |
| Cloudflare API token | Real secret | Regenerate at Cloudflare; apply via `kubectl create secret generic cloudflare-api-token` |
| WireGuard private keys (4) | Real secrets, one per node | Restore from password manager or generate fresh with `wg genkey` and redistribute peers |
| Sealed-Secrets master key | Decryption key for everything in Git | `scripts/dr/sealed-secrets-key-backup.sh` / `-restore.sh` |
| K3s join token | Generated at server install | Read from `ms-1:/var/lib/rancher/k3s/server/node-token` after server install |
| Let's Encrypt ACME account | Auto-regenerated | cert-manager re-registers on fresh install |
| `ADMIN_SSH_ALLOW_IP` (current home IP) | Operator-specific, changes when ISP rotates | Look up at `https://ifconfig.me` and put in `bootstrap/host-prep/firewall/edge-allowlist.env` |
| wk-2 Wi-Fi PSK | Real secret | Restore from password manager or move wk-2 to wired Ethernet |

See [`secret-recovery.md`](secret-recovery.md) for the complete decision
tree.

## Refreshing the pack

The snapshot is dated. After material changes (cluster upgrade, image
version bump, new app), refresh:

```bash
scripts/dr/snapshot-live-state.sh > k8s-cluster/dr/SNAPSHOT-$(date -u +%Y-%m-%d).md
```

Review the new file, then update this README's restoration table if
anything moved.

For drift detection between refreshes:

```bash
scripts/dr/verify-snapshot.sh
```

Run this before any rebuild attempt to catch silent version drift.
