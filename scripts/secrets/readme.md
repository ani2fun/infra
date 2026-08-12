# scripts/secrets

Documented in **[../README.md](../README.md)** — what each script is for, the sealing model, how
to read credentials back, and the gotchas.

Quick reference:

```bash
# read a credential back out of the cluster
scripts/secrets/read-keycloak-admin-credentials.sh
scripts/secrets/read-secret-value.sh <namespace> <secret-name> <key>

# seal a new or rotated secret
scripts/secrets/rotate-generic-secret.sh <namespace> <secret-name> <output-yaml> key=value [key=value ...]

# per-app wrappers (they know the right names, keys and paths)
scripts/secrets/seal-bytebase-secrets.sh [meta-password] [managed-password]
scripts/secrets/seal-synapse-secrets.sh <synapse-admin-client-secret> [db-password]
scripts/secrets/rotate-keycloak-github-oauth.sh <client-id> <client-secret>
```

Needs a working local `kubectl` (WireGuard up, a tunnel, or run from `ms-1`) and `kubeseal`.
