# typing-trainer (Tangent)

Tangent, the Glove80 typing trainer, at <https://typing.kakde.eu>. Source:
[ani2fun/glove80-typing-trainer](https://github.com/ani2fun/glove80-typing-trainer) (private).
Its CI builds `ghcr.io/ani2fun/glove80-typing-trainer:<sha>` (private package) and commits the
new tag into `overlays/prod/kustomization.yaml`; Argo CD (`typing-trainer` app) deploys it.

The image is one Node process serving one page. It has two modes:

- **static** (`base/`, `overlays/dev`): no env, no secrets. Progress stays in each browser.
- **sync** (`overlays/prod`, via `sync.yaml`): visitors can sign in with GitHub through
  Keycloak. Allowed accounts (`ALLOWED_USERS`) get their progress saved in Postgres and merged
  across browsers. Everyone else still uses the trainer, with local-only progress.

`/healthz` never touches Postgres or Keycloak. If either is down, the trainer keeps working and
only sign-in or sync pauses.

## Pieces

| What | Where |
|---|---|
| Keycloak realm `typing`, public PKCE client `typing-web` | `keycloak-realm-prod.json`, applied by `scripts/secrets/sync-typing-keycloak.sh` |
| GitHub OAuth app for that realm | GitHub settings; creds in secret `identity/typing-keycloak-github-oauth` |
| Database `typing`, role `typing` | shared Postgres `databases-prod/postgresql-0`; the app creates its one table (`progress`) |
| Secret `typing-trainer` (`postgres-password`, `session-secret`) | `overlays/prod/sealedsecret.yaml`, from `scripts/secrets/seal-typing-trainer-secrets.sh` |
| Secret `ghcr-pull` (image pull) | `overlays/prod/ghcr-pull-sealedsecret.yaml`, from `scripts/secrets/seal-ghcr-pull-secret.sh` |

`apps-prod` already carries `kakde.eu/postgresql-access=true`, so the Postgres NetworkPolicy
admits the pod. The nightly Postgres backup finds new databases by itself.

## First-time setup

These steps need cluster access (WireGuard up, or run from ms-1). Do them in order:

1. Create a GitHub OAuth app (GitHub → Settings → Developer settings → OAuth Apps → New):
   - Homepage URL: `https://typing.kakde.eu`
   - Authorization callback URL: `https://keycloak.kakde.eu/realms/typing/broker/github/endpoint`
2. Create the realm and the GitHub identity provider. The script prompts for the client secret:

   ```bash
   scripts/secrets/sync-typing-keycloak.sh <github-oauth-client-id>
   ```

3. Seal the app secret and create the database role. Nothing is printed:

   ```bash
   scripts/secrets/seal-typing-trainer-secrets.sh
   ```

4. Commit `overlays/prod/sealedsecret.yaml` and push. Argo CD rolls the pod.

On the first GitHub sign-in, Keycloak may ask once to confirm your name and email (the "first
broker login" flow). After that, sign-in goes straight through.

## Rotation

- **App secret / DB password**: re-run `seal-typing-trainer-secrets.sh`, then commit and push
  right away. It resets the role's password at once, so sync fails until the pod restarts with
  the new Secret. A new session secret also signs everyone out.
- **GitHub OAuth app secret**: create a new secret on the OAuth app, then run
  `sync-typing-keycloak.sh <client-id>` again. With no argument it re-syncs from the stored
  secret.
- **GHCR pull token**: use a classic PAT with only `read:packages`. "No expiration" avoids a yearly
  outage, at the cost of a token that lives until you revoke it.

  ```bash
  scripts/secrets/seal-ghcr-pull-secret.sh apps-prod deploy/apps/typing-trainer/overlays/prod/ghcr-pull-sealedsecret.yaml
  ```

  Commit and push, wait for the pod to pull, then revoke the old token on GitHub.

## Manual database setup (fallback)

`seal-typing-trainer-secrets.sh` does this for you. Only if you sealed with `SKIP_DB=1`:

```bash
kubectl -n databases-prod exec -it postgresql-0 -- sh -lc \
  'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U postgres -d postgres'
```

```sql
CREATE ROLE typing LOGIN PASSWORD '<the sealed postgres-password>';
CREATE DATABASE typing OWNER typing;
```

## Checks

```bash
curl -s https://typing.kakde.eu/api/session   # {"auth":true,"user":null} when sync is configured
kubectl -n apps-prod logs deploy/typing-trainer  # "sign-in and sync enabled for ani2fun"
```
