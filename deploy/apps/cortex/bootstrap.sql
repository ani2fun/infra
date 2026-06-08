-- Cortex Postgres bootstrap (documentation only — NOT auto-run).
--
-- The shared cluster Postgres at postgresql.databases-prod.svc.cluster.local is initialized once
-- via the init ConfigMap. A new app database has to be created manually as a one-off step before
-- cortex can boot. Run this from inside the postgresql-0 pod:
--
--   kubectl -n databases-prod exec -it postgresql-0 -- sh -lc \
--     'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U postgres -d postgres'
--
-- Then paste the SQL below, substituting <chosen-password> with the value you sealed into
-- infra/deploy/apps/cortex/overlays/prod/sealedsecret.yaml (key: postgres-password).
--
-- Liquibase (run by cortex on startup) creates the schema; this file only provisions the role and
-- the empty database that owns it.

CREATE ROLE cortex LOGIN PASSWORD '<chosen-password>';
CREATE DATABASE cortex OWNER cortex;
GRANT ALL PRIVILEGES ON DATABASE cortex TO cortex;

-- The cortex Deployment also requires the `apps-prod` namespace to carry the label
-- `kakde.eu/postgresql-access=true` so the Postgres NetworkPolicy allows ingress (already set for
-- the existing apps in apps-prod; verify with `kubectl get ns apps-prod --show-labels`).
--
-- ---------------------------------------------------------------------------
-- Sealing the password for the cortex Deployment
-- ---------------------------------------------------------------------------
-- The Deployment expects a Secret named `cortex-db` with key `postgres-password`. Seal it from the
-- CLI before applying the overlay (replaces the CHANGE_ME placeholder sealedsecret.yaml):
--
--   echo -n '<chosen-password>' \
--     | kubectl create secret generic cortex-db --dry-run=client \
--         --from-file=postgres-password=/dev/stdin -o yaml \
--     | kubeseal --controller-namespace=sealed-secrets \
--         --controller-name=sealed-secrets-controller \
--         --format yaml \
--         > deploy/apps/cortex/overlays/prod/sealedsecret.yaml
--
-- Edit the result so .metadata.namespace and .spec.template.metadata.namespace are both `apps-prod`
-- (kubeseal omits namespace by default). Mirror deploy/apps/codefolio's previous sealedsecret shape.
