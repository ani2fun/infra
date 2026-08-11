# bytebase

Bytebase — the browser-based database client — behind an oauth2-proxy that authenticates against
Keycloak. Durable platform tooling: it holds credentials to the **production** PostgreSQL in
`databases-prod`, so it is GitOps-managed and self-healing, unlike the disposable
[dblab](../dblab/README.md) lab it also manages.

> **Operators: everything you need is in [OPERATIONS.md](OPERATIONS.md)** — access, adding and
> removing users, rotating secrets, navigating Keycloak, granting database access, and
> troubleshooting. The evaluation write-up is in [FINDINGS.md](FINDINGS.md).

## Why there is a proxy in front

Bytebase's own OIDC SSO is an Enterprise-plan feature, so Keycloak cannot be wired into Bytebase
directly on this licence. oauth2-proxy sits in front and refuses to forward anything until
Keycloak has authenticated the caller **and** confirmed they are in the `bytebase-admins` group.

Consequence, by design: two logins. Keycloak/GitHub at the door, then Bytebase's own local
account. See [FINDINGS.md](FINDINGS.md) §1 for what that costs.

## Layout

| Path | What |
|---|---|
| `base/namespace.yaml` | ns `bytebase`, carrying `kakde.eu/postgresql-access: "true"` |
| `base/deployment.yaml` | Bytebase; metadata in `bytebase_meta` on the shared Postgres via `PG_URL` |
| `base/pvc.yaml` | 5Gi working dir — *not* the metadata store |
| `base/oauth2-proxy-*.yaml` | The access gate. `--allowed-group` is the policy. |
| `base/networkpolicy.yaml` | Default-deny; only Traefik reaches the proxy, only the proxy reaches Bytebase |
| `overlays/prod/ingress.yaml` | `bytebase.kakde.eu` → **the proxy**, never Bytebase directly |
| `overlays/prod/sealedsecret-*.yaml` | Produced by `scripts/secrets/seal-bytebase-secrets.sh` |
| `keycloak-realm-prod.json` | The `bytebase` realm: group, confidential client, groups mapper |
| `bootstrap.sql` | Postgres roles and the per-database grant model (documentation only) |

## Apply

```bash
kubectl apply -k deploy/apps/bytebase/overlays/prod
```

Once this directory is committed and pushed, apply
`deploy/platform/argocd/applications/bytebase.yaml` and Argo CD takes over. Do not apply that
Application before the push — Argo syncs from GitHub and would sit permanently degraded.

## Not finished yet

The Keycloak realm has **no identity provider**, so nobody can log in until a GitHub OAuth app
exists. See [OPERATIONS.md §7](OPERATIONS.md).
