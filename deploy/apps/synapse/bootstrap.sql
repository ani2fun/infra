-- Synapse Postgres bootstrap (documentation only — NOT auto-run).
--
-- The shared cluster Postgres at postgresql.databases-prod.svc.cluster.local is initialized once
-- via the init ConfigMap; a new app database is a manual one-off (the same step cortex needed).
-- Run this from inside the postgresql-0 pod:
--
--   kubectl -n databases-prod exec -it postgresql-0 -- sh -lc \
--     'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U postgres -d postgres'
--
-- Then paste the SQL below, substituting <chosen-password> with the value you sealed into
-- deploy/apps/synapse/overlays/prod/sealedsecret-db.yaml (key: postgres-password) via
-- scripts/secrets/seal-synapse-secrets.sh.
--
-- Liquibase (run by synapse at startup) creates the schema — submissions + the
-- submission_allowlist table; this file only provisions the role and the empty database.

CREATE ROLE synapse LOGIN PASSWORD '<chosen-password>';
CREATE DATABASE synapse OWNER synapse;
GRANT ALL PRIVILEGES ON DATABASE synapse TO synapse;

-- Prod enforces the submit allowlist (SUBMISSION_ALLOWLIST_ENFORCED=true): only rows in
-- submission_allowlist may submit-and-save. Grants are live SQL — no redeploy. After the first
-- boot (Liquibase has created the table), connect to the synapse db and add yourself:
--
--   \c synapse
--   INSERT INTO submission_allowlist (username, note) VALUES ('<keycloak-username>', 'owner');
--
-- The apps-prod namespace must carry `kakde.eu/postgresql-access=true` for the Postgres
-- NetworkPolicy (already set for the existing apps; verify with
-- `kubectl get ns apps-prod --show-labels`).
--
-- Backups: scripts/dr/postgres-backup.sh discovers databases dynamically (SELECT datname FROM
-- pg_database), so the synapse db joins the backup scope automatically — no script change.
--
-- ---------------------------------------------------------------------------
-- Keycloak: the `synapse` realm (realm-per-app, ADR-S033)
-- ---------------------------------------------------------------------------
-- Synapse validates JWTs against https://keycloak.kakde.eu/realms/synapse and the browser does
-- public PKCE as client `synapse-web` (GET /api/auth/config serves the coordinates — both come
-- from the Deployment's OIDC_ISSUER/OIDC_AUDIENCE).
--
-- Import the realm from synapse's realm-as-code file, RE-TEMPLATED for prod — never verbatim:
--   source: synapse repo, dev-tools/keycloak/synapse-realm.json
--   changes: drop the dev seed users (tester/test1) · set the synapse-web client's
--     redirectUris/webOrigins to https://synapse.kakde.eu/* · keep the client public+PKCE.
-- Import via Keycloak admin console (Add realm → import) at https://keycloak.kakde.eu, or kcadm.
--
-- The Deployment also needs the sealed Keycloak-admin copy in apps-prod
-- (sealedsecret-keycloak-admin.yaml — the canonical secret lives in the `identity` namespace and
-- cannot be referenced across namespaces): seal it with scripts/secrets/seal-synapse-secrets.sh.
