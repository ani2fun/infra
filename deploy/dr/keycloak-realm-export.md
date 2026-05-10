# Keycloak realm export and import

The `kakde` realm holds every OIDC client (dsa-tracker, oauth2-proxy,
codefolio, future apps), the GitHub identity provider config, role
mappings, and user accounts. **All of that lives only in the Keycloak
PostgreSQL schema.** Lose the schema and you lose every client
configuration.

The `scripts/dr/postgres-backup.sh` script captures the schema as part of
the postgres dump, which is the primary defence. This document covers a
secondary, portable defence: a JSON realm export captured via the Keycloak
admin REST API. JSON is safer to keep alongside other operator notes and
makes recovery on a fresh Keycloak straightforward without needing the
exact same postgres state.

## Why use the REST API instead of `kc.sh export`

`kc.sh export` requires stopping the running Keycloak process, which means
brief downtime. The admin REST API captures the same data live without any
service interruption.

## What the export includes

- the realm settings (login flow, themes, locale, registration policy)
- every client (id, secret, redirect URIs, scopes, role mappings)
- identity providers (GitHub OAuth broker)
- user federation, authentication flows, default roles
- password policies and themes
- (with `exportClients=true`) the realm role definitions

## What the export does NOT include

- **GitHub OAuth client secret** -- regenerate at github.com on restore.
- **User passwords** -- the JSON does not contain plaintext (good); user
  password hashes are included only when `exportClients=true` is paired
  with `userProfileEnabled` in the right config. Treat user passwords as
  reset-on-restore.
- Active user sessions and offline tokens.
- Database-level state like `pg_stat_*`.

## Cadence

Run after any change to:

- realm settings or login flow
- a client's redirect URIs, scopes, or secrets
- the GitHub IdP config
- user federation

A monthly cron is a reasonable baseline if you don't make config changes
often.

## Export procedure

```bash
scripts/dr/backup-keycloak-realm.sh /path/to/secure/dir/
```

The script:

1. Reads admin credentials via `scripts/secrets/read-keycloak-admin-credentials.sh`.
2. Obtains an access token from
   `https://keycloak.kakde.eu/realms/master/protocol/openid-connect/token`.
3. Calls `GET /admin/realms/kakde?exportClients=true`.
4. Writes `kakde-realm-YYYYMMDDTHHMMSSZ.json` (mode `0600`).
5. Prints SHA-256 and a reminder about secret material that is **not**
   included.

## Import procedure on a fresh Keycloak

After a fresh Keycloak StatefulSet is up and the postgres `keycloak`
database is empty (Keycloak has run its initial schema migrations but no
realm exists yet):

1. Copy the JSON onto a node:

   ```bash
   scp kakde-realm-*.json ms-1:/tmp/kakde-realm.json
   ```

2. Copy it into the Keycloak pod:

   ```bash
   ssh ms-1 'kubectl -n identity cp /tmp/kakde-realm.json $(kubectl -n identity get pod -l app=keycloak -o name | head -1):/tmp/kakde-realm.json'
   ```

3. Import:

   ```bash
   ssh ms-1 'kubectl -n identity exec -it $(kubectl -n identity get pod -l app=keycloak -o name | head -1) -- /opt/keycloak/bin/kc.sh import --file /tmp/kakde-realm.json --override true'
   ```

4. Restart the Keycloak pod so the import takes effect cleanly:

   ```bash
   ssh ms-1 'kubectl -n identity rollout restart deploy/keycloak'
   ```

## Post-import checklist

- Verify discovery URL: `curl -sI https://keycloak.kakde.eu/realms/kakde/.well-known/openid-configuration | head -1` (expect `200`).
- For every client in the realm, confirm the redirect URIs match the
  current public hosts.
- Update the GitHub OAuth client's secret in the realm's IdP settings
  (regenerated at github.com).
- Reapply `keycloak-github-oauth` SealedSecret with the new secret value
  using `scripts/secrets/rotate-keycloak-github-oauth.sh`.
- Force an end-to-end auth flow via `https://whoami-auth.kakde.eu`.

## See also

- `scripts/dr/backup-keycloak-realm.sh` -- the export wrapper
- `scripts/dr/postgres-backup.sh` -- primary backup of all postgres data including the realm
- [`secret-recovery.md`](secret-recovery.md) -- per-secret recovery decisions
