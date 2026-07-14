# Synapse — production deployment runbook (from scratch)

The complete, ordered procedure that takes **synapse.kakde.eu** from an empty cluster footprint to
serving — including every credential retrieval/creation step. Design rationale lives in the synapse
repo (`docs/adr-synapse/README.md`, ADR-S033); this file is the *operations* truth. Everything was
executed and verified on 2026-07-14.

## What gets deployed (the shape)

| App (ArgoCD) | Path | What it is |
|---|---|---|
| `synapse` | `deploy/apps/synapse/overlays/prod` | The Scala app (`ghcr.io/ani2fun/synapse`, 1 replica — per-pod rate limiter, deliberate) + a **git-sync sidecar** pulling `ani2fun/synapse-content` (public, anonymous https) into a shared emptyDir every 60s. The server reads `SYNAPSE_ROOT=/content/current` and re-indexes when the checkout's HEAD SHA moves — **prose publishing = `git push`, no redeploy**. Ingress `synapse.kakde.eu`. |
| `synapse-go-judge` | `deploy/apps/synapse-go-judge/overlays/prod` | Synapse's **own** sandbox (`ghcr.io/ani2fun/synapse-go-judge`, built from the synapse repo's `runner/go-judge/`): privileged (cgroup-v2 sandboxing), pinned to wk-1, references the existing `go-judge-low` PriorityClass, `ES_PARALLELISM=1`, isolation NetworkPolicy (ingress only from synapse, all egress denied). |
| `synapse-likec4` | `deploy/apps/synapse-likec4/overlays/prod` | The merged `/c4` diagram SPA (`ghcr.io/ani2fun/synapse-likec4`, built by **synapse-content**'s CI from every `.c4` in that repo). Runs on the edge node; only consumer is synapse's `/c4/*` proxy. |

Two Secrets in `apps-prod` (sealed into git):

- **`synapse-db`** (`postgres-password`) — the app's Postgres role password.
- **`synapse-keycloak-admin`** (`username`, `password`) — a sealed **copy** of the Keycloak bootstrap
  admin. Needed because the canonical `keycloak-admin-secret` lives in the `identity` namespace and
  pods cannot reference Secrets across namespaces; synapse's account-deletion adapter calls the
  Keycloak Admin API with it.

## 0. Prerequisites

- **Cluster access**: WireGuard tunnel up so `kubectl` works locally (or run kubectl steps on `ms-1`
  over ssh). `kubeseal` installed locally (sealing is offline against a fetched cert — see step 2).
- **Images on GHCR**: pushing synapse `main` builds `synapse`; `runner/go-judge/**` changes build
  `synapse-go-judge`; pushing `.c4` files to synapse-content builds `synapse-likec4`. First-time
  bootstrap: trigger each workflow once (`gh workflow run` or any push) and wait for green.
- **GitHub Actions secrets** on BOTH `ani2fun/synapse` and `ani2fun/synapse-content`
  (Settings → Secrets → Actions), same values as `ani2fun/cortex` uses:
  - `INFRA_REPO_TOKEN` — a PAT with `repo` (contents write) scope on `ani2fun/infra`; the promote
    step commits the new image tag into the kustomize overlay with it.
  - `INFRA_GIT_USER_NAME` / `INFRA_GIT_USER_EMAIL` — the git identity of those promote commits.
  Until these exist, the build still pushes images; only the infra promotion warns and skips.
- The `apps-prod` namespace must carry `kakde.eu/postgresql-access=true` (it already does; verify
  with `kubectl get ns apps-prod --show-labels`).

## 1. Manifests

All of `deploy/apps/synapse{,-go-judge,-likec4}` + the three ArgoCD Applications are on infra
`main`. Sanity-check they render:

```bash
kubectl kustomize deploy/apps/synapse/overlays/prod >/dev/null && echo ok
kubectl kustomize deploy/apps/synapse-go-judge/overlays/prod >/dev/null && echo ok
kubectl kustomize deploy/apps/synapse-likec4/overlays/prod >/dev/null && echo ok
```

## 2. Secrets — retrieve, create, seal, commit

`scripts/secrets/seal-synapse-secrets.sh` does everything (fetches the Sealed Secrets cert via
`fetch-sealed-secrets-cert.sh`, seals offline with `kubeseal --cert`, writes both sealedsecret
YAMLs). You feed it the Keycloak admin pair and optionally a db password (it generates one
otherwise **and prints it — copy it, step 3 needs it**):

```bash
cd ~/Development/homelab/infra

# retrieve the Keycloak bootstrap-admin credentials (canonical copy, identity namespace)
KC_USER=$(kubectl -n identity get secret keycloak-admin-secret -o jsonpath='{.data.username}' | base64 -d)
KC_PASS=$(kubectl -n identity get secret keycloak-admin-secret -o jsonpath='{.data.password}' | base64 -d)

# seal both secrets (generates + PRINTS the fresh db password)
scripts/secrets/seal-synapse-secrets.sh "$KC_USER" "$KC_PASS"

git add deploy/apps/synapse/overlays/prod/sealedsecret-*.yaml
git commit -m "chore(synapse): seal runtime secrets"
git pull --rebase origin main   # CI promote commits land on main continuously — always rebase
git push origin main
```

**Rotation** = re-run the same script (new db password → also re-run the `ALTER ROLE synapse
PASSWORD` variant of step 3), commit, push; ArgoCD + the sealed-secrets controller roll the pod.

## 3. Postgres — create the role and database

The shared instance (`databases-prod/postgresql-0`) only auto-creates its first database; every app
db is a manual one-off. Use the password printed in step 2:

```bash
kubectl -n databases-prod exec -it postgresql-0 -- sh -lc \
  'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U postgres -d postgres'
```

```sql
CREATE ROLE synapse LOGIN PASSWORD '<the-printed-password>';
CREATE DATABASE synapse OWNER synapse;
GRANT ALL PRIVILEGES ON DATABASE synapse TO synapse;
```

Schema comes from Liquibase at the app's first boot — nothing else to create. **Backups need no
change**: `scripts/dr/postgres-backup.sh` discovers databases dynamically.

## 4. Keycloak — import the `synapse` realm

Realm-per-app (ADR-S033): synapse validates JWTs against
`https://keycloak.kakde.eu/realms/synapse`; the browser does public PKCE as `synapse-web` (the app
serves the coordinates from its `OIDC_ISSUER`/`OIDC_AUDIENCE` env via `GET /api/auth/config`).

Import the pre-templated file (`deploy/apps/synapse/keycloak-realm-prod.json` — derived from the
synapse repo's `dev-tools/keycloak/synapse-realm.json`: dev seed users dropped, prod redirect URIs,
`sslRequired: external`, direct-access grants off). The kcadm login uses the pod's own admin env —
no credentials typed:

```bash
cd ~/Development/homelab/infra
kubectl -n identity exec -i deploy/keycloak -- bash -c \
  '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master \
     --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" \
   && /opt/keycloak/bin/kcadm.sh create realms -f -' \
  < deploy/apps/synapse/keycloak-realm-prod.json

# verify
curl -sf https://keycloak.kakde.eu/realms/synapse/.well-known/openid-configuration | head -c 120
```

> **Gotcha (hit on first import):** Keycloak's `CLIENT.DESCRIPTION` column is `varchar(255)`. A
> longer client description fails the whole import with the opaque `Database operation failed`
> (the transaction rolls back cleanly — just fix and re-run). The server log
> (`kubectl -n identity logs deploy/keycloak --since=10m`) has the real
> `value too long for type character varying(255)` error.

**Accounts**: the realm imports with **no users and registration off**. Create your account in the
admin console (https://keycloak.kakde.eu → realm `synapse` → Users → Create), or flip
`registrationAllowed`, or wire the GitHub IdP like `apps-prod`
(`scripts/secrets/sync-keycloak-github-idp.sh` is the precedent).

## 5. ArgoCD — apply the three Applications

Applications are applied manually (repo convention — no app-of-apps):

```bash
kubectl apply \
  -f deploy/platform/argocd/applications/synapse.yaml \
  -f deploy/platform/argocd/applications/synapse-go-judge.yaml \
  -f deploy/platform/argocd/applications/synapse-likec4.yaml

kubectl get applications -n argocd | grep synapse       # → Synced / Healthy (app needs ~2 min: JVM + Liquibase)
kubectl -n apps-prod get pods | grep synapse
```

From here everything is GitOps: a synapse `main` push builds → GHCR → CI patches the overlay's
`images:` tag → ArgoCD (automated, prune+selfHeal) rolls it out. Content pushes never touch the
cluster at all — the git-sync sidecar picks them up within a minute.

## 6. Cloudflare (dashboard)

1. DNS: `synapse` A/CNAME → the edge, **Proxied** (orange cloud).
2. SSL/TLS mode: **Full (strict)** (zone-wide already).
3. **CAA records must allow BOTH `letsencrypt.org` AND `pki.goog`** — an LE-only CAA silently
   breaks Cloudflare's edge-certificate renewal (a documented cortex incident).
4. **Cache Rule** (this is what makes far-region reading fast): match
   `synapse.kakde.eu/api/synapse/*` OR `synapse.kakde.eu/api/blog/*` → *Eligible for cache*,
   respect origin headers. The origin stamps those responses
   `public, max-age=60, stale-while-revalidate=600` (matched to the git-sync cadence), so PoPs
   serve lesson JSON locally. Hashed `/assets/*` (immutable, 1y) and `/media/*` (1h) edge-cache by
   default once proxied; HTML and every other `/api/*` route stay DYNAMIC.

## 7. Submit allowlist

Prod runs `SUBMISSION_ALLOWLIST_ENFORCED=true`: signed-in users can read/run, but only allow-listed
usernames may submit-and-save. After the app's first boot (Liquibase has created the table):

```bash
kubectl -n databases-prod exec -it postgresql-0 -- sh -lc \
  'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U postgres -d synapse'
```

```sql
INSERT INTO submission_allowlist (username, note) VALUES ('<keycloak-username>', 'owner');
```

Grants are live — no restart.

## 8. Verify (the parity checklist)

```bash
# health + the four speed layers
curl -s https://synapse.kakde.eu/api/health                                   # {"status":...}
curl -sI -H 'Accept-Encoding: gzip' https://synapse.kakde.eu/api/synapse/index \
  | grep -Ei 'content-encoding|cache-control'                                 # gzip + max-age=60/swr
ENTRY=$(curl -s https://synapse.kakde.eu/ | grep -o 'assets/[^"]*\.js' | head -1)
curl -sI "https://synapse.kakde.eu/$ENTRY" | grep -Ei 'cache-control|cf-cache-status'
                                                # immutable, 1y; cf-cache-status HIT on 2nd request
curl -sI https://synapse.kakde.eu/index.html | grep -i cache-control          # no-cache

# the no-redeploy content pipeline
# push a trivial edit to synapse-content main → re-curl the lesson within ~a minute → it changed.
```

In the browser: read a lesson (media, mermaid/d2 diagrams), run code, **Visualise** a hinted
python/java fence, sign in (realm `synapse`), **Edit** lesson code while signed in, submit on a
problem (403 without an allowlist row, 202 with), open a `/c4` architecture diagram, ⌘K search,
blog, the library tour.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `404 page not found` at the domain | Traefik has no router → the ArgoCD Applications aren't applied (step 5). |
| App pod `CreateContainerConfigError` | The two Secrets don't exist → sealed placeholders still in git, or the controller can't unseal (re-run step 2). |
| App crash-loops on Liquibase / connection refused | The `synapse` db/role doesn't exist (step 3), or wrong password (re-seal + `ALTER ROLE`). |
| Realm import: `Database operation failed` | See the step-4 gotcha — usually a >255-char field; read the Keycloak pod log for the real column error. |
| `git push` to infra rejected | CI promote commits land on `main` continuously — `git pull --rebase origin main` then push. |
| Sign-in fails with realm/issuer errors | Realm not imported, or the Deployment's `OIDC_ISSUER` doesn't match `https://keycloak.kakde.eu/realms/synapse`. |
| Edge cert renewal fails later | CAA got tightened to LE-only — re-allow `pki.goog` too. |
| LikeC4 image builds but diagrams are broken | Never name the content-repo dockerfile `Dockerfile.likec4` — likec4 parses `**/*.likec4` as model sources; it must stay `likec4.Dockerfile`. |
| `/c4/` 404 through the domain while the likec4 pod is healthy | The app's proxy STRIPS the `/c4` prefix and the nginx image serves the SPA UNDER `/c4/` — `LIKEC4_URL` must be `http://synapse-likec4/c4` (hit + fixed on first deploy). |
