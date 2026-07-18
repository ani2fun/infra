# Synapse — production deployment runbook (from scratch)

The complete, ordered procedure that takes **synapse.kakde.eu** from an empty cluster footprint to
serving — including every credential retrieval/creation step. Design rationale lives in the synapse
repo; this file is the *operations* truth. Everything was executed and verified on 2026-07-14.

> **The app has been Rust since 2026-07-18.** The Scala implementation was replaced **in place** by
> the rebuild from `ani2fun/synapse-rs`: same ArgoCD app, Service, Ingress, TLS cert, hostname,
> Postgres database, go-judge and likec4 — only the image and the env shape changed. Rollback is
> reverting the cutover commit; `ghcr.io/ani2fun/synapse:cde344a72a5330b981290fa91aeaba498c49c1bc`
> is still in GHCR and must not be pruned while the Rust app is settling. What changed operationally:
>
> - **`DATABASE_URL` is a `postgres://` URL**, not JDBC, with the password interpolated by
>   Kubernetes via `$(DB_PASSWORD)`. There is no `DATABASE_USER`/`DATABASE_PASSWORD` pair any more,
>   and the sealed password must stay URL-safe (the generator already strips `/+=`).
> - **`enableServiceLinks: false` is load-bearing** — see Troubleshooting.
> - **Readiness moved to `/api/ready`**, which pings Postgres. `/api/health` stays deliberately
>   shallow and is what liveness and startup use.
> - Migrations are **sqlx**, not Liquibase. The existing schema was adopted by inserting baseline
>   rows into `_sqlx_migrations`; Liquibase's own tables remain and are inert.
> - Resources dropped to 64Mi/256Mi — the pod idles near **6Mi**, against the JVM's 256Mi floor.

## What gets deployed (the shape)

| App (ArgoCD) | Path | What it is |
|---|---|---|
| `synapse` | `deploy/apps/synapse/overlays/prod` | The Scala app (`ghcr.io/ani2fun/synapse`, 1 replica — per-pod rate limiter, deliberate) + a **git-sync sidecar** pulling `ani2fun/synapse-content` (public, anonymous https) into a shared emptyDir every 60s. The server reads `SYNAPSE_ROOT=/content/current` and re-indexes when the checkout's HEAD SHA moves — **prose publishing = `git push`, no redeploy**. Ingress `synapse.kakde.eu`. |
| `synapse-go-judge` | `deploy/apps/synapse-go-judge/overlays/prod` | Synapse's **own** sandbox (`ghcr.io/ani2fun/synapse-go-judge`, built from the synapse repo's `runner/go-judge/`): privileged (cgroup-v2 sandboxing), pinned to wk-1, references the existing `go-judge-low` PriorityClass, `ES_PARALLELISM=1`, isolation NetworkPolicy (ingress only from synapse, all egress denied). |
| `synapse-likec4` | `deploy/apps/synapse-likec4/overlays/prod` | The merged `/c4` diagram SPA (`ghcr.io/ani2fun/synapse-likec4`, built by **synapse-content**'s CI from every `.c4` in that repo). Runs on the edge node; only consumer is synapse's `/c4/*` proxy. |

Two Secrets in `apps-prod` (sealed into git):

- **`synapse-db`** (`postgres-password`) — the app's Postgres role password.
- **`synapse-keycloak-admin`** (`client-secret`) — the secret of the **`synapse-admin`** confidential
  service-account client (step 37). Account deletion authenticates as this client
  (`client_credentials`), scoped to `realm-management:manage-users` on the `synapse` realm only —
  least privilege, NOT the master-realm admin.

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

> **Service-account client (step 37):** the realm file also seeds `synapse-admin` — a confidential
> service-account client the server uses for account deletion. On a from-scratch import, Keycloak
> generates its secret: read it (`kcadm get clients/<id>/client-secret -r synapse`), seal it into
> `synapse-keycloak-admin` key `client-secret` (`kubectl create secret … | kubeseal --cert …`), and
> commit. On this cluster it was created live with kcadm + `add-roles … --rolename manage-users`.
>
> **Gotcha (hit on first import):** Keycloak's `CLIENT.DESCRIPTION` column is `varchar(255)`. A
> longer client description fails the whole import with the opaque `Database operation failed`
> (the transaction rolls back cleanly — just fix and re-run). The server log
> (`kubectl -n identity logs deploy/keycloak --since=10m`) has the real
> `value too long for type character varying(255)` error.

**Accounts — GitHub sign-in (the intended path)**: the realm imports with no users and registration
off. Wire the GitHub identity provider with `scripts/secrets/sync-synapse-github-idp.sh`:

1. Create the realm's OWN GitHub OAuth app (OAuth apps carry ONE callback URL, so apps-prod's can't
   be shared): GitHub → Settings → Developer settings → OAuth Apps → New OAuth App —
   Homepage `https://synapse.kakde.eu`, callback
   `https://keycloak.kakde.eu/realms/synapse/broker/github/endpoint`.
2. `scripts/secrets/sync-synapse-github-idp.sh <client-id> <client-secret>` — stores them as the
   `synapse-keycloak-github-oauth` secret (identity namespace) and creates/updates the IdP. Re-run
   with no args to re-sync; with new args to rotate.
3. Keycloak imports the GitHub **login** as the username, so the JWT's `preferred_username` is the
   GitHub handle — exactly what `ADMIN_USERS` and the submit allowlist key on.

Alternatives: create users in the admin console, or flip `registrationAllowed`.

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
usernames may submit-and-save. **The normal path is the `/admin` panel** (step 35): sign in as a user
listed in the Deployment's `ADMIN_USERS` (currently `ani2fun`) → account menu → Admin panel → grant
the username. Grants are live. **Fresh-database note:** Liquibase's changeset 002 seeds two dev rows
(`tester`, `test1` — note "dev realm seed", there so local dev works out of the box). They are inert
in prod (no such users exist in the `synapse` realm) but appear in the panel on a from-scratch
deploy — revoke them from `/admin`. SQL remains the break-glass path (e.g. before the first admin can
sign in — though the admin gate itself is env-based, so the admin just needs an account):

```bash
kubectl -n databases-prod exec -it postgresql-0 -- sh -lc \
  'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U postgres -d synapse'
```

```sql
INSERT INTO submission_allowlist (username, note) VALUES ('<keycloak-username>', 'owner');
```

Grants are live — no restart.

## Admins & the allowlist — the authorization model

Two independent lists, on purpose:

| | What it controls | Where it lives | How it changes | Live? |
|---|---|---|---|---|
| **`ADMIN_USERS`** | who may open `/admin` and manage the allowlist | env var in `deploy/apps/synapse/base/deployment.yaml` (comma-separated IdP usernames) | git commit + push → ArgoCD rolls the pod | no — needs a redeploy |
| **submit allowlist** | who may submit-and-save | `submission_allowlist` Postgres table | the `/admin` panel (or SQL) | yes — next request, no restart |

**Nothing is hardcoded in the application.** `ADMIN_USERS` is read into `AppConfig.admin`; every
`/api/admin/*` call re-authenticates the bearer and checks `username ∈ ADMIN_USERS` server-side
(anonymous → 401, signed-in non-admin → 403). The `admin:true` flag on `/api/me` only makes the panel
*appear* — the server never trusts it for authority.

**Add another admin:**
```bash
cd ~/Development/homelab/infra
# deploy/apps/synapse/base/deployment.yaml → ADMIN_USERS value: ani2fun,new-handle
git commit -am "feat(synapse): add new-handle to ADMIN_USERS" && git push
```
ArgoCD rolls the pod (~1 min); that user gets the panel on their next sign-in. Remove = same edit
in reverse. With GitHub sign-in the username IS the GitHub handle (Keycloak imports the login).

**Check who is admin right now:**
```bash
kubectl -n apps-prod get deploy synapse \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ADMIN_USERS")].value}'
```

**Deliberate asymmetry (a security choice):** allowlist grants are live and self-service (an admin
grants from the UI), but admin-ship changes ONLY through the GitOps trail — a commit, reviewable,
never a button. A compromised admin session can grant submit access but **cannot mint new admins**.
Admin ≠ allowlisted: an admin who wants to submit still grants themselves a row.

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

## Security posture & audit (2026-07-14)

A full review of the auth + admin + platform surfaces. Fixed in code (step 36): username
case-normalization (the admin gate and allowlist now compare a canonical lowercase username, closing
a `Ani2fun` vs `ani2fun` silent-403 and an `Alice`/`alice` double-identity), and **baseline security
headers** at the origin (nosniff, X-Frame-Options SAMEORIGIN, Referrer-Policy, a CSP that allows only
self + the Keycloak origin for connect/frame, HSTS) — verified not to break the OIDC sign-in round
trip.

**Accepted CSP costs** (both broke prod when omitted; the policy is otherwise same-origin):
`script-src` carries `'unsafe-inline'` (index.html's theme-bootstrap script + Cloudflare's injected
beacon loader — neither can carry a nonce) and `'unsafe-eval'` (d2 spawns its render worker as a
`blob:` worker, which inherits the page CSP, and that worker loads its embedded ELK layout engine
via `new Function` at init — even under the dagre layout; `'wasm-unsafe-eval'` covers only WASM,
and no directive scopes eval to one worker). Without `'unsafe-eval'` every d2 diagram fails with an
EvalError card. Dev never shows CSP breakage: Vite serves the SPA without the origin's headers —
validate CSP changes against prod-shaped serving and the heaviest pages (Monaco + d2).

**Verified clean:** RS256 pinned (no alg-confusion / alg:none), issuer+audience+expiry checked, JWKS
cached/rotated; account deletion is self-only (token's own `sub`); submission delete/erase are
owner-scoped (no IDOR); every SQL path is a PreparedStatement; the content cache header never stamps
an authenticated route; LikeC4 proxy host is fixed (no SSRF); media/static path-traversal guards hold
(realpath + confine); the admin panel renders via Laminar text nodes (no XSS); tokens live in
keycloak-js memory (not localStorage); no secrets in the repo.

**Known items (not yet done — see the roadmap):**

- ✅ **DONE (step 37) — the master-realm credential is gone.** Account deletion now authenticates as
  the `synapse-admin` confidential service-account client (`client_credentials`), scoped to
  `realm-management:manage-users` on the `synapse` realm only. A pod-env leak can at worst delete users
  in this one realm.
- ✅ **DONE (step 37) — the app runs non-root** (`runAsUser: 65532` + a pod `fsGroup: 65532` so it reads
  the git-sync emptyDir), on top of the dropped caps / no-priv-escalation / RuntimeDefault it already had.
- **MEDIUM — GitHub IdP hardening**: the realm's `first broker login` flow has **Review Profile =
  REQUIRED**, so a first-time GitHub user sees an editable username field. Keycloak's uniqueness blocks
  claiming an *existing* handle, but before wiring the IdP set Review Profile to DISABLED (or trust the
  broker username) so the GitHub login is imported verbatim — no chance to hand-edit into a
  configured-but-unregistered `ADMIN_USERS` name.
- **LOW — `/api/me` token verification is un-rate-limited** (mild CPU-amplification with junk tokens).
  Consider extending the RateLimiter to it.

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
| `/c4/` 404 through the domain while the likec4 pod is healthy | The app's proxy STRIPS the `/c4` prefix and the nginx image serves the SPA UNDER `/c4/` — `LIKEC4_URL` must be `http://synapse-likec4/c4` (hit + fixed on first deploy). Separately, the trailing-slash form needed its own route in the proxy: axum's `{*rest}` wildcard doesn't match an empty remainder (fixed 2026-07-18). |
| App CrashLoopBackOff with `expected u16 for key "PORT"` | Kubernetes injects legacy Docker-link env for every Service in the namespace, and this Service is named `synapse` — so it injects `SYNAPSE_PORT=tcp://10.43.x.x:80`, which overrides the image's `8080` and fails to parse. Keep **`enableServiceLinks: false`** on the pod spec. Found by booting the real image in `apps-prod` during the cutover rehearsal. |
| App boots but the catalog is empty | `SYNAPSE_ROOT` must be `/content/**current**` (git-sync's symlink), not the `/content` mount — the image's own default is the mount. |
| Pod `CreateContainerConfigError` right after re-sealing secrets | `seal-synapse-secrets.sh` takes the **`synapse-admin` client secret** (sealed as key `client-secret`), not the Keycloak bootstrap admin pair. It used to seal `username`/`password`, which no longer matches the Deployment (corrected 2026-07-18). |
