# whoami test apps

Two test apps for verifying the ingress and (when enabled) the OIDC flow.

## What is currently deployed

Only the unauthenticated `whoami` is live in the cluster:

- Namespace: `apps`
- Deployment + Service + Ingress at `whoami.kakde.eu`
- Image: `traefik/whoami:latest`

Run `curl -sI https://whoami.kakde.eu` and expect `HTTP/2 200`.

## What is NOT currently deployed

`whoami-auth.kakde.eu` (OAuth2-Proxy in front of `whoami`) is documented
in the inventory and the manifests are present here as **deployable
templates**, but the resources are not on the cluster as of the snapshot
date. They are kept here so deploying the auth variant later is one
SealedSecret + two `kustomize` uncomments away.

To activate `whoami-auth`:

1. Confirm a `whoami-oauth2-proxy` Keycloak client exists (or create it
   in the `kakde` realm) with redirect URI
   `https://whoami-auth.kakde.eu/oauth2/callback`.

2. Seal the runtime Secret:

   ```bash
   scripts/secrets/seal-whoami-oauth2-proxy.sh \
     <keycloak-client-id> <keycloak-client-secret>
   ```

   This writes `overlays/prod/sealedsecret-oauth2-proxy.yaml`.

3. In `base/kustomization.yaml`, uncomment the `oauth2-proxy-*.yaml`
   resource lines.

4. In `overlays/prod/kustomization.yaml`, uncomment the
   `sealedsecret-oauth2-proxy.yaml` and `ingress-whoami-auth.yaml`
   resource lines.

5. Apply:

   ```bash
   kubectl apply -k deploy/apps/whoami/overlays/prod/
   ```

6. Verify: `curl -sI https://whoami-auth.kakde.eu` should return `302`
   redirecting to the Keycloak login.

## Secrets

The `whoami-oauth2-proxy` runtime Secret has three keys:

| Key | Source | Notes |
|---|---|---|
| `client-id` | the Keycloak client name | e.g. `whoami-oauth2-proxy` |
| `client-secret` | the Keycloak client's "Credentials" tab | rotate via Keycloak admin |
| `cookie-secret` | random 32 bytes, base64 | `head -c 32 /dev/urandom \| base64` |

Generate and seal in one go via
`scripts/secrets/seal-whoami-oauth2-proxy.sh`. See
[`../../dr/secret-recovery.md`](../../dr/secret-recovery.md) for the full
secret recovery decision tree.
