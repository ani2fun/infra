# `scripts/` — operator tooling

Every script here is run **by hand, from the operator's laptop**, against the live cluster.
Nothing in this tree runs automatically: no CronJob, no Argo CD hook, no CI. If a script ran,
someone chose to run it.

Two directories, two jobs:

| | What it does | When you reach for it |
|---|---|---|
| [`secrets/`](#secrets) | Create, rotate and read credentials; wire Keycloak identity providers | Day-to-day. Adding an app, rotating a leaked key, "what was that password?" |
| [`dr/`](#dr) | Back up and restore the things that cannot be rebuilt from Git; capture cluster state | Before something risky, on a schedule you keep yourself, and during a rebuild |

The **procedures** live in [`deploy/dr/`](../deploy/dr/) — RUNBOOK, gates, the secret-recovery
decision tree. This file documents the **tools** those procedures invoke. When the two disagree,
the procedure doc wins.

---

## The one thing to understand first

The two directories reach the cluster in **different ways**, and it matters:

- **`secrets/*` use your local `kubectl`.** They need a working kubeconfig — WireGuard up, or an
  SSH tunnel, or run them from `ms-1` directly. Some also need `kubeseal`.
- **`dr/*` SSH to `ms-1` themselves** and run `kubectl` there with
  `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`. They need `ssh ms-1` to work non-interactively
  (`BatchMode=yes`); they do **not** care about your local kubeconfig at all.

So a broken local kubeconfig breaks every `secrets/` script and no `dr/` script. That asymmetry
is the usual reason one set works while the other does not.

### Prerequisites

```bash
kubectl version --client     # secrets/*
kubeseal --version           # secrets/* that seal
jq --version                 # the Keycloak IdP sync scripts
ssh -o BatchMode=yes ms-1 true && echo ok    # dr/*
```

---

## `secrets/`

### Sealing model, in one paragraph

Secrets are **never** committed in plaintext. A script builds a Kubernetes Secret in memory,
pipes it through `kubeseal`, and writes an encrypted `SealedSecret` YAML into the app's overlay —
which *is* committed. Only the controller in the cluster can decrypt it. Sealing needs the
cluster's public cert; `rotate-generic-secret.sh` fetches that automatically if missing, so you
rarely call `fetch-sealed-secrets-cert.sh` yourself.

Consequence worth internalising: **losing the Sealed Secrets master key makes every committed
SealedSecret permanently undecryptable.** That is what `dr/sealed-secrets-key-backup.sh` exists
to prevent.

### The primitives

| Script | Purpose |
|---|---|
| `rotate-generic-secret.sh <ns> <name> <out.yaml> key=value…` | The workhorse. Everything else that seals wraps this. |
| `rotate-docker-registry-secret.sh <ns> <name> <out.yaml> <server> <user> <pass> [email]` | Same, for a `dockerconfigjson` pull secret. |
| `fetch-sealed-secrets-cert.sh [path]` | Pull the cluster's sealing cert. Defaults to `/tmp/sealed-secrets-cert.pem`; override with `$SEALED_SECRETS_CERT`. |
| `read-secret-value.sh <ns> <name> <key>` | Print one decoded value from a live Secret. |

### Reading credentials back

You are not expected to remember generated passwords — read them from the cluster.

```bash
scripts/secrets/read-keycloak-admin-credentials.sh          # username= / password=
scripts/secrets/read-keycloak-db-password.sh
scripts/secrets/read-secret-value.sh identity keycloak-github-oauth client-id
scripts/secrets/read-secret-value.sh bytebase bytebase-db managed-password
```

### Per-app sealing wrappers

Thin shells over `rotate-generic-secret.sh` that know an app's secret names, keys and output
paths, so you cannot get them subtly wrong.

| Script | App | Notes |
|---|---|---|
| `seal-bytebase-secrets.sh [meta-pw] [managed-pw]` | bytebase | Reads the Keycloak client secret **straight out of Keycloak**, so it is never copy-pasted. Generates URL-safe passwords if not supplied. |
| `seal-synapse-secrets.sh <admin-client-secret> [db-pw]` | synapse | The DB password must stay URL-safe — it is interpolated into a `postgres://` URL. |
| `seal-cortex-tutor-secrets.sh <anthropic-key> [mcp-token]` | cortex-tutor | App is parked in `deploy/platform/argocd/applications/inactive/`. |
| `rotate-keycloak-github-oauth.sh <client-id> <client-secret>` | keycloak | Seals **and**, if the cluster is reachable, applies it and re-syncs the live IdP. |

### Keycloak identity providers

One script per realm, because **a GitHub OAuth app carries exactly one callback URL** — realms
cannot share an app.

| Script | Realm | Callback URL to register on GitHub |
|---|---|---|
| `sync-keycloak-github-idp.sh` | `apps-prod` (via `$KEYCLOAK_REALM`) | `…/realms/apps-prod/broker/github/endpoint` |
| `sync-synapse-github-idp.sh [id secret]` | `synapse` | `…/realms/synapse/broker/github/endpoint` |
| `sync-bytebase-github-idp.sh [id secret]` | `bytebase` | `…/realms/bytebase/broker/github/endpoint` |

All are create-or-update and idempotent. Pass the client id and secret on first run; later runs
need no arguments and re-sync from the stored Secret.

### Access control

```bash
scripts/secrets/grant-bytebase-admin.sh --list            # who can reach bytebase.kakde.eu
scripts/secrets/grant-bytebase-admin.sh <github-handle>   # grant
scripts/secrets/grant-bytebase-admin.sh --revoke <user>   # revoke
```

Membership of the `bytebase-admins` Keycloak group **is** the access policy — oauth2-proxy runs
with `--allowed-group=bytebase-admins`. The GitHub OAuth app restricts nobody: any GitHub account
can authorize it and get a realm user created. See
[`deploy/apps/bytebase/OPERATIONS.md`](../deploy/apps/bytebase/OPERATIONS.md) §2.

---

## `dr/`

These protect the state that **cannot** be reconstructed from this repository: PostgreSQL data,
the Sealed Secrets master key, and Keycloak realm configuration. Everything else — manifests,
scripts, docs — is in Git and rebuildable.

Read [`deploy/dr/RUNBOOK.md`](../deploy/dr/RUNBOOK.md) for the order to use them in during an
actual rebuild.

### Backup and restore

| Script | Notes |
|---|---|
| `postgres-backup.sh <out-dir>` | Discovers all non-template databases automatically, dumps globals plus one custom-format dump each, bundles to a tarball. **Read-only — safe on a live cluster.** New databases are picked up with no script change. |
| `postgres-restore.sh <backup.tar.gz>` | Globals first, then each database with `--create --clean --if-exists`. Verifies row counts against the tarball's inventory. **`--clean` DROPS matching objects — never point it at a live database you care about.** |
| `sealed-secrets-key-backup.sh <out-dir>` | Exports the master key, `chmod 0600`. Put it in a password manager or encrypted USB. **Never commit it.** |
| `sealed-secrets-key-restore.sh <key.yaml>` | Run **after** installing the controller and **before** applying any committed SealedSecret. Validates, scales the controller down, applies, scales back up, prints the cert digest to compare against `SNAPSHOT.md`. |
| `backup-keycloak-realm.sh <out-dir>` | Realm export over the admin REST API — no downtime, unlike `kc.sh export`. |

Backups go to **whatever directory you pass**. Choose encrypted, off-cluster storage: a backup on
the node it protects is not a backup.

### Cluster state

| Script | Notes |
|---|---|
| `snapshot-live-state.sh > out.md` | Markdown fragment of live state: per-node OS/kernel/sysctl/firewall, K3s and Calico versions, image+digest pairs for every workload, Argo revisions, PVs. Read-only. Paste into `deploy/dr/SNAPSHOT.md`. |
| `verify-snapshot.sh` | Compares live headline versions against `SNAPSHOT.md`. **Exits 0 on no drift, 1 on drift** — so it works in a check loop. Currently reports one false positive; see gotchas. |

Digests matter more than tags: tags move, digests do not. `SNAPSHOT.md` is what a rebuild pins to.

---

## Gotchas

**`backup-keycloak-realm.sh` defaults to `REALM=kakde`, and that is now only one realm of five.**
Live realms are `master`, `kakde`, `apps-prod`, `synapse`, `bytebase`. A plain run backs up
`kakde` only and looks successful. Back up each realm you care about:

```bash
for r in kakde apps-prod synapse bytebase; do
  REALM=$r scripts/dr/backup-keycloak-realm.sh ~/backups/keycloak
done
```

**`sync-keycloak-github-idp.sh` defaults to `KEYCLOAK_REALM=apps-prod`**, unlike its
per-realm siblings which hard-code their realm. Check which realm you are pointing at.

**`verify-snapshot.sh` always reports at least one drift, and that one is false.** Verified
2026-08-11:

```
DRIFT K3s kubelet   expected=`v1.35.1+k3s1`   actual=v1.35.1+k3s1
```

Identical versions. The `snap_version()` awk trims surrounding whitespace but not the **markdown
backticks** that `SNAPSHOT.md` wraps every version in, so the comparison can never match. A
drift detector that cries wolf on every run is worse than none — you stop reading it. One-line
fix: strip backticks alongside whitespace in that `gsub`.

Argo `DRIFT … (not in snapshot)` lines are different and usually legitimate — they mean
`SNAPSHOT.md` predates the current commits and genuinely needs regenerating.

**`seal-whoami-oauth2-proxy.sh` is orphaned.** It writes to
`deploy/apps/whoami/overlays/prod/`, deleted in `36d9411` when whoami was retired. It cannot
work as written. Kept only because it is a compact reference for sealing an oauth2-proxy triple
(`client-id` / `client-secret` / `cookie-secret`) — for a working version of that pattern, use
`seal-bytebase-secrets.sh`.

**Sealing while the cluster is unreachable fails confusingly.** `kubeseal` needs the cert, and
the cert comes from the cluster. Bring WireGuard up or run from `ms-1`.

**A rotated password has two homes.** Sealing writes the new value into Git; the database or
Keycloak still holds the old one. Change both, seal first, then apply. Miss the second half and
the app fails to authenticate with a perfectly valid-looking committed secret.

---

## Adding a script here

Match what is already there:

- `#!/usr/bin/env bash` and `set -euo pipefail`
- A header comment saying what it does, **why** it exists, and a `Usage:` line — several scripts
  here document a non-obvious trap in that header, which is the point
- Idempotent where it can be; destructive only where it must be, and say so loudly
- Take paths as arguments rather than hard-coding them; `${VAR:-default}` for anything an
  operator might reasonably want to override
- Never write a secret to stdout unless that is the script's stated job
- `chmod +x`, and add it to the right table above
