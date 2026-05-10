-- Codefolio Postgres bootstrap (documentation only — NOT auto-run).
--
-- The shared cluster Postgres at postgresql.databases-prod.svc.cluster.local
-- is initialized once via the init ConfigMap with the `appuser`/`appdb` pair.
-- A new app database has to be created manually as a one-off step before
-- codefolio can boot. Run this from inside the postgresql-0 pod:
--
--   kubectl -n databases-prod exec -it postgresql-0 -- sh -lc \
--     'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U postgres -d postgres'
--
-- Then paste the SQL below, substituting <chosen-password> with the value
-- you sealed into infra/deploy/codefolio/overlays/prod/sealedsecret.yaml
-- (key: postgres-password).
--
-- Liquibase (run by codefolio on startup) creates the schema; this file
-- only provisions the role and the empty database that owns it.

CREATE ROLE codefolio LOGIN PASSWORD '<chosen-password>';
CREATE DATABASE codefolio OWNER codefolio;
GRANT ALL PRIVILEGES ON DATABASE codefolio TO codefolio;

-- The codefolio Deployment also requires the `apps-prod` namespace to carry
-- the label `kakde.eu/postgresql-access=true` so the Postgres NetworkPolicy
-- allows ingress. Verify with:
--
--   kubectl get ns apps-prod --show-labels
--
-- And if missing:
--
--   kubectl label namespace apps-prod kakde.eu/postgresql-access=true --overwrite
--
-- ---------------------------------------------------------------------------
-- Sealing the password for the codefolio Deployment
-- ---------------------------------------------------------------------------
-- The Deployment expects a Secret named `codefolio-db` with key
-- `postgres-password`. Seal it from CLI before applying the overlay:
--
--   echo -n '<chosen-password>' \
--     | kubectl create secret generic codefolio-db --dry-run=client \
--         --from-file=postgres-password=/dev/stdin -o yaml \
--     | kubeseal --controller-namespace=sealed-secrets \
--         --controller-name=sealed-secrets-controller \
--         --format yaml \
--         > deploy/codefolio/overlays/prod/sealedsecret.yaml
--
-- Edit the resulting file so .metadata.namespace and .spec.template.metadata.namespace
-- are both `apps-prod` (kubeseal omits namespace by default). Mirror the shape of
-- deploy/dsa-tracker/overlays/prod/sealedsecret.yaml.
