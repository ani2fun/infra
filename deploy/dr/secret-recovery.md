# Secret recovery decision tree

For every secret in the cluster: where the plaintext comes from on rebuild
day, how to apply it, and what breaks if it's lost.

## Summary table

| Secret | Namespace | Source on rebuild | Restored by | Blast radius if lost |
|---|---|---|---|---|
| `cloudflare-api-token` | `cert-manager` | Regenerate at Cloudflare | `kubectl create secret` | TLS cert renewal stops; existing certs keep working until expiry (~60 days) |
| `postgresql-auth` | `databases-prod` | Password manager | `kubectl create secret` | Postgres won't start with the configured roles; recoverable by setting matching values |
| `dsa-tracker-db` | `apps-prod` | Sealed-secrets restore (preferred) or postgres password rotation | sealed-secrets controller, or `scripts/secrets/rotate-generic-secret.sh` | dsa-tracker backend can't reach postgres |
| `codefolio-db` | `apps-prod` | Sealed-secrets restore (preferred) or postgres password rotation | sealed-secrets controller, or `scripts/secrets/rotate-generic-secret.sh` | codefolio backend can't reach mongo/redis |
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

**Apply.** Edit `deploy/platform/postgresql/2-secret.yaml` to
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

### `dsa-tracker-db` (apps-prod)

**Why it's needed.** Postgres role password used by the dsa-tracker
backend. SealedSecret committed at
`deploy/apps/dsa-tracker/overlays/prod/sealedsecret.yaml`.

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
       deploy/apps/dsa-tracker/overlays/prod/sealedsecret.yaml \
       postgres-password='<<NEW>>'
     ```

---

### `codefolio-db` (apps-prod)

**Why it's needed.** Database password used by the codefolio backend.
SealedSecret committed at
`deploy/apps/codefolio/overlays/prod/sealedsecret.yaml`.

**Source on rebuild.** Same procedure as `dsa-tracker-db` above; sub the
codefolio file path and credential keys.

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
# update each node's /etc/wireguard/wg0.conf PublicKey fields
# wg-quick down wg0 && wg-quick up wg0
```

This is more work but always works. Bootstrap-time WireGuard configs are
maintained out of band (operator notes, not in this repo).

---

### wk-2 Wi-Fi PSK

**Why it's tracked here.** Currently wk-2 connects to `Macaw-Tucan` Wi-Fi
with the PSK in plaintext inside `/etc/netplan/50-cloud-init.yaml`.

**Recommended.** Move wk-2 to wired Ethernet on rebuild. Wi-Fi is fragile
under K8s load and the PSK in netplan is awkward to manage.

**If staying on Wi-Fi.** Pull the PSK from the password manager. Edit
the netplan file in place. Set `chmod 600` on the netplan file before
`netplan apply`.

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
home IP at `https://ifconfig.me` and put it in `/etc/edge-allowlist.env`
on `vm-1`. Then re-apply `deploy/platform/traefik/edge-guardrail.sh`.

If your ISP rotates the IP between rebuild and your next remote login,
SSH will be blocked. Recover via the Contabo web console.
