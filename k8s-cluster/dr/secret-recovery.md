# Secret recovery decision tree

For every secret in the cluster: where the plaintext comes from on rebuild
day, how to apply it, and what breaks if it's lost.

## Summary table

| Secret | Namespace | Source on rebuild | Restored by | Blast radius if lost |
|---|---|---|---|---|
| `cloudflare-api-token` | `cert-manager` | Regenerate at Cloudflare | `kubectl create secret` | TLS cert renewal stops; existing certs keep working until expiry (~60 days) |
| `postgresql-auth` | `databases-prod` | Password manager | `kubectl create secret` | Postgres won't start with the configured roles; recoverable by setting matching values |
| `keycloak-admin-secret` | `identity` | Password manager | `kubectl create secret` | Lose admin console access; recreate via `KC_BOOTSTRAP_ADMIN_*` env on a fresh Keycloak |
| `keycloak-db-secret` | `identity` | Password manager (must match `pg_authid`) | `kubectl create secret` | Keycloak can't connect to its DB; rotate role + secret together |
| `keycloak-github-oauth` | `identity` | Sealed-secrets restore (preferred) or rotate at github.com | sealed-secrets controller, or `scripts/secrets/rotate-keycloak-github-oauth.sh` | GitHub login broker fails; users can still use direct Keycloak accounts |
| `dsa-tracker-db` | `apps-prod` | Sealed-secrets restore (preferred) or postgres password rotation | sealed-secrets controller, or `scripts/secrets/rotate-generic-secret.sh` | dsa-tracker backend can't reach postgres |
| `whoami-oauth2-proxy` | `apps` (when deployed) | Generate fresh values | `scripts/secrets/seal-whoami-oauth2-proxy.sh` | whoami-auth.kakde.eu fails; whoami.kakde.eu unaffected |
| TLS cert Secrets (`*-tls`) | various | cert-manager re-issues automatically | cert-manager | Brief unavailability while DNS-01 challenge completes |
| WireGuard private keys | each node `/etc/wireguard/wg0.key` | Password manager (4 entries) or generate fresh | `scp` + `wg-quick down/up wg0` | Mesh fails; cluster API unreachable; rebuild from L2 |
| wk-2 Wi-Fi PSK | wk-2 `/etc/netplan/*.yaml` | Password manager | netplan template fill-in | wk-2 can't reach the LAN; switch to wired Ethernet to recover |
| K3s join token | (generated on `ms-1`) | `cat /var/lib/rancher/k3s/server/node-token` after server install | install-agent scripts read it | Workers can't join; cluster sits at 1 node |
| Sealed-Secrets master key | `kube-system` | Off-cluster backup | `scripts/dr/sealed-secrets-key-restore.sh` | Every committed `SealedSecret` becomes garbage; regenerate plaintexts at source |
| `ADMIN_SSH_ALLOW_IP` | not a secret, but operator-specific | `https://ifconfig.me` | Edit `/etc/edge-allowlist.env` and re-apply edge-guardrail | SSH to vm-1 only via Contabo web console |

---

## Detailed walkthroughs

### `cloudflare-api-token` (cert-manager)

**Why it's needed.** ClusterIssuers use the Cloudflare DNS-01 solver to
prove control of `kakde.eu`. Without this Secret cert-manager cannot
respond to ACME challenges.

**Source on rebuild.**

1. Sign in to Cloudflare.
2. My Profile → API Tokens → Create Token.
3. Use the "Edit zone DNS" template scoped to `kakde.eu`.
4. Copy the resulting token.

**Apply.**

```bash
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token='<<NEW_TOKEN>>'
```

The ClusterIssuers reference `secretRef.name=cloudflare-api-token`,
`secretRef.key=api-token`. They become `Ready=True` within seconds of the
Secret being applied.

---

### `postgresql-auth` (databases-prod)

**Why it's needed.** Bootstrap Secret read by the `postgresql` StatefulSet
on first start. Sets the superuser password, the application database
name, and the application role's password. After first start these values
must match what's already in the database (if you restore a postgres
backup) or postgres will refuse to authenticate.

**Source on rebuild.**

- Look up the live values in your password manager. Your password manager
  should have a single entry for `postgresql-auth` with these keys:
  `postgres-superuser-password`, `app-db-name`, `app-db-user`,
  `app-db-password`.

**Apply.** Edit `k8s-cluster/platform/postgresql/2-secret.yaml` to
substitute the placeholder values, or apply directly:

```bash
kubectl -n databases-prod create secret generic postgresql-auth \
  --from-literal=postgres-superuser-password='...' \
  --from-literal=app-db-name='appdb' \
  --from-literal=app-db-user='appuser' \
  --from-literal=app-db-password='...'
```

**If you've forgotten the values:** recreate fresh, then on first start
postgres uses them to provision new roles. If you also restored a
postgres backup, you must update the role passwords inside the DB to
match (`ALTER ROLE appuser WITH PASSWORD '...';`).

---

### `keycloak-admin-secret` (identity)

**Why it's needed.** Bootstrap admin user (read on Keycloak's first
start). Once Keycloak is running you log in to the admin console with
this credential and can manage users/clients from there.

**Source on rebuild.** Password manager.

**Apply.**

```bash
kubectl -n identity create secret generic keycloak-admin-secret \
  --from-literal=username='<<ADMIN_USER>>' \
  --from-literal=password='<<ADMIN_PASS>>'
```

**If lost.** Pick fresh values, apply, restart Keycloak. The new admin
will have access; no realm data is lost.

---

### `keycloak-db-secret` (identity)

**Why it's needed.** Keycloak connects to PostgreSQL with these
credentials. They must match a real role+password in `pg_authid` (so
postgres accepts the login) AND in the `keycloak` database's owner
permissions.

**Source on rebuild.**

- If you've restored a postgres dump, the role+password in the dump is
  the source of truth -- pull the matching plaintext from the password
  manager.
- If you're starting from a fresh empty postgres, choose values, then
  create the role + database to match:

  ```bash
  kubectl -n databases-prod exec -it postgresql-0 -- psql -U postgres -c \
    "CREATE ROLE keycloak WITH LOGIN PASSWORD '<<PASS>>'; \
     CREATE DATABASE keycloak OWNER keycloak;"
  ```

**Apply.**

```bash
kubectl -n identity create secret generic keycloak-db-secret \
  --from-literal=username='keycloak' \
  --from-literal=password='<<PASS>>'
```

---

### `keycloak-github-oauth` (identity)

**Why it's needed.** GitHub identity-broker client ID and secret.
Committed to Git as a SealedSecret at
`k8s-cluster/apps/keycloak/overlays/prod/github-oauth-sealedsecret.yaml`.

**Source on rebuild.**

- **If sealed-secrets master key was restored:** restored automatically
  by the controller when you `kubectl apply` the SealedSecret. Nothing
  more to do.
- **If the master key is unrecoverable:**
  1. Go to github.com → Settings → Developer settings → OAuth Apps.
  2. Find the "Keycloak `kakde` realm" app.
  3. Generate a new client secret. Copy it.
  4. Reseal:

     ```bash
     scripts/secrets/rotate-keycloak-github-oauth.sh \
       <<github-client-id>> <<new-client-secret>>
     ```

  5. Argo CD or `kubectl apply` will pick up the new SealedSecret.

---

### `dsa-tracker-db` (apps-prod)

**Why it's needed.** Postgres role password used by the dsa-tracker
backend. SealedSecret committed at
`deploy/dsa-tracker/overlays/prod/sealedsecret.yaml`.

**Source on rebuild.**

- **If sealed-secrets master key was restored:** automatic.
- **If unrecoverable:**
  1. Pick a new password.
  2. Update postgres:
     `ALTER ROLE appuser WITH PASSWORD '<<NEW>>';` (or whatever the role
     name is for dsa-tracker).
  3. Reseal:

     ```bash
     scripts/secrets/rotate-generic-secret.sh \
       apps-prod dsa-tracker-db \
       deploy/dsa-tracker/overlays/prod/sealedsecret.yaml \
       postgres-password='<<NEW>>'
     ```

---

### `whoami-oauth2-proxy` (apps)

**Why it's needed.** Three keys: Keycloak client id/secret + a
`cookie-secret` for oauth2-proxy session cookies. Only needed when the
`whoami-auth.kakde.eu` flow is activated.

**Note:** as of the snapshot, whoami-auth is **not deployed**. The
manifests in `apps/whoami/` are deployable templates; activate via the
README in that directory.

**Source on rebuild.**

- Keycloak client id: chosen at client creation in the `kakde` realm.
- Keycloak client secret: from the client's "Credentials" tab.
- `cookie-secret`: generate fresh (`head -c 32 /dev/urandom | base64`).

**Apply via the helper:**

```bash
scripts/secrets/seal-whoami-oauth2-proxy.sh \
  <<keycloak-client-id>> <<keycloak-client-secret>>
```

The helper generates the cookie-secret automatically and writes the
SealedSecret next to the manifests.

---

### TLS Secret resources (`*-tls`)

Auto-managed by cert-manager. Do **not** back them up. On a fresh cluster
with cert-manager + ClusterIssuers + the Cloudflare token in place, every
Ingress with a TLS reference will trigger a cert issuance within 1-2
minutes.

If a cert isn't reissuing:

```bash
ssh ms-1 'kubectl get certificate,certificaterequest,order,challenge -A'
# look for "False" Ready status; the message column tells you why
```

---

### WireGuard private keys

**Why this is the highest blast radius secret.** If wg0 doesn't come up,
the cluster has no overlay; nothing else works.

**Best path: restore from password manager.**

Each of the four nodes has its own private key. Store one entry per node
in the password manager (`wg0.key/ms-1`, `wg0.key/wk-1`, etc.). On
rebuild:

```bash
ssh ms-1 'umask 077; cat > /etc/wireguard/wg0.key' <<<'<<MS1_PRIVATE_KEY>>'
```

The wg-quick service reads this file at start.

**Alternative: regenerate.**

If you don't have backups, generate fresh keys and update **all four**
peer configs to use the new public keys:

```bash
ssh ms-1 'umask 077; wg genkey | tee /etc/wireguard/wg0.key | wg pubkey'
# repeat on each node, capture the public key for each
# update bootstrap/wireguard/*.conf.example PublicKey fields
# scp the example to each node, edit in the right private key reference
# wg-quick down wg0 && wg-quick up wg0
```

This is more work but always works.

---

### wk-2 Wi-Fi PSK

**Why it's tracked here.** Currently wk-2 connects to `Macaw-Tucan` Wi-Fi
with the PSK in plaintext inside `/etc/netplan/50-cloud-init.yaml`. The
template at `bootstrap/host-prep/netplan/wk-2.yaml.example` ships with a
placeholder.

**Recommended.** Move wk-2 to wired Ethernet on rebuild. Wi-Fi is fragile
under K8s load and the PSK in netplan is awkward to manage.

**If staying on Wi-Fi.** Pull the PSK from the password manager. Replace
the `<<REPLACE_WITH_WIFI_PSK>>` placeholder in the netplan file. Set
`chmod 600` on the netplan file before `netplan apply`.

---

### K3s join token

Not really a secret you back up -- it's regenerated on every K3s server
install. After running `install-server-ms-1.sh`:

```bash
ssh ms-1 'cat /var/lib/rancher/k3s/server/node-token'
```

Use that value in each agent install command.

---

### Sealed-Secrets master key

The biggest single point of failure. Detailed procedure:
[`sealed-secrets-key-backup.md`](sealed-secrets-key-backup.md).

---

### `ADMIN_SSH_ALLOW_IP`

Not a secret per se, just operator-specific. The `edge_guardrail`
nftables allowlist permits SSH from a single IP. On rebuild, look up your
home IP at `https://ifconfig.me` and put it in
`bootstrap/host-prep/firewall/edge-allowlist.env`. Then re-apply
`platform/traefik/edge-guardrail.sh`.

If your ISP rotates the IP between rebuild and your next remote login,
SSH will be blocked. Recover via the Contabo web console.
