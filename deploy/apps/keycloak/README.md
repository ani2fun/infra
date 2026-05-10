# Keycloak

`base/` and `overlays/prod/` reflect the live Keycloak deployment in the
`identity` namespace. Image: `quay.io/keycloak/keycloak:26.5.5`. Database:
PostgreSQL StatefulSet in `databases-prod`.

## Layout

- `base/deployment.yaml` -- Keycloak Deployment (1 replica, anti-affinity off the edge node)
- `base/service.yaml` -- ClusterIP `keycloak` (port 80 -> 8080)
- `overlays/prod/ingress.yaml` -- `keycloak.kakde.eu` (cert-manager, Traefik)
- `overlays/prod/github-oauth-sealedsecret.yaml` -- `keycloak-github-oauth` (encrypted)
- `overlays/prod/kustomization.yaml`

## Secrets referenced

- `keycloak-admin-secret` -- bootstrap admin (keys: `username`, `password`).
  Plaintext source: password manager. See [`../../dr/secret-recovery.md`](../../dr/secret-recovery.md).
- `keycloak-db-secret` -- DB role (keys: `username`, `password`). Must
  match the role recorded in `pg_authid`. See secret-recovery doc.
- `keycloak-github-oauth` -- restored automatically by sealed-secrets if the
  controller key is present, otherwise regenerated at github.com and resealed
  via `scripts/secrets/rotate-keycloak-github-oauth.sh`.

## Realm export and import

The `kakde` realm contains every OIDC client config and lives only in the
PostgreSQL `keycloak` database. Export it as portable JSON via:

```bash
scripts/dr/backup-keycloak-realm.sh /path/to/secure/dir/
```

Full procedure: [`../../dr/keycloak-realm-export.md`](../../dr/keycloak-realm-export.md).

## Live cluster verification

```bash
curl -sI https://keycloak.kakde.eu/realms/kakde/.well-known/openid-configuration | head -1
# expected: HTTP/2 200
```

## See also

- [`../../dr/RUNBOOK.md`](../../dr/RUNBOOK.md) -- operator runbook (Layer 9)
- [`../../platform/postgresql/README.md`](../../platform/postgresql/README.md) -- backend database
- [`../../dr/secret-recovery.md`](../../dr/secret-recovery.md) -- secret-by-secret recovery
