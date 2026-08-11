-- Bytebase Postgres bootstrap (documentation only — NOT auto-run).
--
-- Two separate concerns live in this file:
--   1. bytebase_meta — the database Bytebase stores its OWN state in (instances, users,
--      settings, issue history). Bytebase writes this itself; we only create the role + db.
--   2. bytebase     — the login role Bytebase USES to manage other databases on this
--      instance. This is the one that shows up in the "Create Instance" form.
--
-- Run from inside the postgresql-0 pod:
--
--   kubectl -n databases-prod exec -it postgresql-0 -- sh -lc \
--     'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U postgres -d postgres'
--
-- Substitute <meta-password> and <bytebase-password> with the values sealed via
-- scripts/secrets/seal-bytebase-secrets.sh. Never commit the real values.
--
-- Verified against the live instance: PostgreSQL 17.9, existing databases are
-- appdb, codefolio, dsa_tracker, keycloak, synapse, testdb.


-- ---------------------------------------------------------------------------
-- 1. Bytebase's own metadata store
-- ---------------------------------------------------------------------------
-- Deliberately on the shared cluster Postgres rather than a dedicated one:
-- scripts/dr/postgres-backup.sh discovers databases dynamically
-- (SELECT datname FROM pg_database), so this joins the DR backup scope with no script
-- change. That matters — losing it means re-registering every instance by hand in the UI,
-- because instance registration is not scriptable on the free tier.
--
-- Do NOT register this database as an instance inside Bytebase.

CREATE ROLE bytebase_meta LOGIN PASSWORD '<meta-password>';
CREATE DATABASE bytebase_meta OWNER bytebase_meta;


-- ---------------------------------------------------------------------------
-- 2. The role Bytebase manages other databases with
-- ---------------------------------------------------------------------------
-- Full DDL + DML, explicitly NOT a superuser: it cannot touch pg_authid, create or drop
-- roles, read server files, or install untrusted extensions. A mistake in the SQL editor
-- is survivable; a superuser mistake on this instance is not.

CREATE ROLE bytebase LOGIN PASSWORD '<bytebase-password>';


-- ---------------------------------------------------------------------------
-- 3. Granting access, one database at a time
-- ---------------------------------------------------------------------------
-- Grant deliberately and individually. There is no loop here on purpose: the set of
-- databases Bytebase can write to should be something you can read off this file.
--
-- Two ways to do it. Prefer (a).
--
-- (a) ROLE MEMBERSHIP — bytebase inherits everything the owning role can do, including
--     on tables that do not exist yet. This is what makes it genuinely "full DDL + DML"
--     without revisiting the grants every time an app runs a migration.
--
--       GRANT <owner-role> TO bytebase;
--
-- (b) EXPLICIT GRANTS — narrower, but you must also fix up DEFAULT PRIVILEGES or Bytebase
--     silently loses access to every table created after today:
--
--       \c <database>
--       GRANT CONNECT ON DATABASE <database> TO bytebase;
--       GRANT USAGE, CREATE ON SCHEMA public TO bytebase;
--       GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO bytebase;
--       GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO bytebase;
--       ALTER DEFAULT PRIVILEGES FOR ROLE <owner-role> IN SCHEMA public
--         GRANT ALL ON TABLES TO bytebase;
--       ALTER DEFAULT PRIVILEGES FOR ROLE <owner-role> IN SCHEMA public
--         GRANT ALL ON SEQUENCES TO bytebase;
--
--     Note the `FOR ROLE <owner-role>` — ALTER DEFAULT PRIVILEGES only affects objects
--     created by the role it names. Omitting it silently does nothing useful here, because
--     the app's own role is what creates the tables, not postgres.

-- Sensible starting scope: the throwaway databases first, so you can learn the migration
-- workflow somewhere a mistake costs nothing.
GRANT appuser TO bytebase;      -- covers appdb, dsa_tracker, testdb

-- Application databases. Added 2026-08-10 after Bytebase hit
--   ERROR: permission denied for table submissions (SQLSTATE 42501)
-- browsing the synapse database. Membership is what makes this work for tables that do not
-- exist yet, so a future Liquibase/sqlx migration will not silently lock Bytebase out again.
GRANT synapse   TO bytebase;
GRANT codefolio TO bytebase;

-- Membership only takes effect if the member role INHERITs. `bytebase` was created with the
-- default (rolinherit = t), so nothing extra is needed — but if a role is ever created
-- NOINHERIT, membership grants appear to do nothing and it is baffling. Check with:
--   SELECT rolname, rolinherit FROM pg_roles WHERE rolname = 'bytebase';

-- ⚠️  keycloak gets READ-ONLY, never membership.
--     Keycloak's database is what authenticates you INTO Bytebase (via the bytebase realm and
--     oauth2-proxy). A bad migration there locks you out of the tool you would use to fix it,
--     and out of Grafana, Synapse and the admin console at the same time. So it is browsable
--     but not writable — applied 2026-08-10 and verified: SELECT works, while INSERT, UPDATE,
--     DELETE and CREATE TABLE are all refused.
--
--     Run these connected to the keycloak database (\c keycloak):
--
--       GRANT CONNECT ON DATABASE keycloak TO bytebase;
--       GRANT USAGE ON SCHEMA public TO bytebase;
--       GRANT SELECT ON ALL TABLES    IN SCHEMA public TO bytebase;
--       GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO bytebase;
--       -- Keycloak upgrades add tables; without this they arrive invisible and the grant
--       -- silently rots. FOR ROLE keycloak is load-bearing — default privileges only apply
--       -- to objects created by the role they name, and keycloak creates these, not postgres.
--       ALTER DEFAULT PRIVILEGES FOR ROLE keycloak IN SCHEMA public
--         GRANT SELECT ON TABLES    TO bytebase;
--       ALTER DEFAULT PRIVILEGES FOR ROLE keycloak IN SCHEMA public
--         GRANT SELECT ON SEQUENCES TO bytebase;
--
-- GRANT keycloak TO bytebase;   -- DO NOT: membership inherits ownership, i.e. full write.


-- ---------------------------------------------------------------------------
-- 4. Revoking access later
-- ---------------------------------------------------------------------------
--   REVOKE <owner-role> FROM bytebase;              -- undoes (a)
--   REVOKE ALL PRIVILEGES ON DATABASE <db> FROM bytebase;   -- undoes (b), plus the
--                                                           -- schema/table grants above


-- ---------------------------------------------------------------------------
-- 5. Networking
-- ---------------------------------------------------------------------------
-- deploy/platform/postgresql/5-networkpolicy.yaml is default-deny and only admits
-- namespaces labelled kakde.eu/postgresql-access=true. The bytebase namespace ships that
-- label on its own Namespace object (deploy/apps/bytebase/base/namespace.yaml) so it stays
-- declarative — label-access.sh only covers apps-prod.
--
-- Verify with:  kubectl get ns bytebase --show-labels
--
-- Bytebase reaches Postgres at postgresql.databases-prod.svc.cluster.local:5432. In the
-- "Create Instance" form that Service DNS name is the host — never localhost, never a node IP.


-- ---------------------------------------------------------------------------
-- 6. Backups
-- ---------------------------------------------------------------------------
-- scripts/dr/postgres-backup.sh enumerates databases at run time, so both bytebase_meta and
-- anything Bytebase creates are picked up automatically. No script change needed.
