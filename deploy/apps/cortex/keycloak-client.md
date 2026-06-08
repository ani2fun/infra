# Cortex — Keycloak client (`cortex-web`)

Cortex validates JWTs against the homelab Keycloak (`https://keycloak.kakde.eu`). The realm state
lives in the Keycloak Postgres DB, **not** in a manifest — so this client is created once by the
operator via the admin console or `kcadm`, before `AUTH_ENABLED=true` cortex is deployed.

## Client to create

- **Realm:** `apps-prod` (matches the cortex Deployment's `KEYCLOAK_ISSUER_URL` /
  `KEYCLOAK_REALM`). If your live prod realm is named differently, change those two env values in
  `base/deployment.yaml` to match.
- **Client ID:** `cortex-web`
- **Type:** public (no client secret), PKCE
- **Settings:**
  - `Standard flow` enabled; `Direct access grants` off
  - `Proof Key for Code Exchange Code Challenge Method` = `S256`
  - **Valid redirect URIs:** `https://cortex.kakde.eu/*`, `https://dev.cortex.kakde.eu/*`
    (add `http://localhost:5173/*` + `http://localhost:8080/*` if you also want this realm for local dev)
  - **Valid post-logout redirect URIs:** same as redirect URIs
  - **Web origins:** `https://cortex.kakde.eu`, `https://dev.cortex.kakde.eu`, `+`

## `kcadm` recipe (inside the keycloak pod)

```sh
kubectl -n identity exec -it deploy/keycloak -- bash
/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
  --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"

/opt/keycloak/bin/kcadm.sh create clients -r apps-prod \
  -s clientId=cortex-web \
  -s publicClient=true -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
  -s 'attributes."pkce.code.challenge.method"=S256' \
  -s 'redirectUris=["https://cortex.kakde.eu/*","https://dev.cortex.kakde.eu/*"]' \
  -s 'webOrigins=["https://cortex.kakde.eu","https://dev.cortex.kakde.eu","+"]'
```

## GitHub federation

The local-dev realm (in the cortex repo at `docker/keycloak/import/cortex-realm.json`) has no GitHub
IdP — "Continue with GitHub" lands on Keycloak's own login form. Production's `apps-prod` realm should
already federate GitHub (the existing homelab setup); the `cortex-web` client inherits it.

## Dev note

The `overlays/dev` kustomization sets `AUTH_ENABLED=false`, so `dev.cortex.kakde.eu` runs unlocked and
needs no Keycloak client. Only prod requires `cortex-web`.
