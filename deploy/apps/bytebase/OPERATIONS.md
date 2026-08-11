# Bytebase + database lab — operator cookbook

Everything you need to run, access, and change this setup. Commands here were run against the
live cluster on 2026-08-10 unless a step is explicitly marked **NOT YET VERIFIED**.

Two separate things are documented here, and they have different lifecycles:

| | Namespace | Lifecycle | Managed by |
|---|---|---|---|
| **Bytebase** + oauth2-proxy | `bytebase` | Durable — holds production DB credentials | Argo CD (once pushed) |
| **The lab** — 6 engines + Kafka/RabbitMQ | `dblab` | Disposable — start and stop at will | `lab-*.sh` scripts, never Argo |

---

## 0. Before anything: how you talk to the cluster

Two options. The SSH tunnel is more convenient but dropped mid-session at least once during
this build, so know the fallback.

```bash
ssh -N -L 6443:192.168.15.2:6443 ms-1
```

Your kubeconfig currently points at `https://127.0.0.1:16443` while that tunnel listens on
**6443** — so plain `kubectl` will not work until you reconcile the two. Either change the
kubeconfig server to `:6443`, or start the tunnel on 16443 instead.

The fallback needs no tunnel at all and is what most of this document was verified with:

```bash
ssh ms-1 'kubectl -n dblab get pods'
```

To apply local manifests through it, render locally and pipe:

```bash
kubectl kustomize deploy/apps/dblab/base | ssh ms-1 'kubectl apply -f -'
```

---

## 1. Access

### 1.1 Reaching Bytebase

<https://bytebase.kakde.eu>

**You will log in twice, and that is expected.** Bytebase's own OIDC SSO is an Enterprise-plan
feature, so Keycloak cannot be wired into Bytebase directly. Instead oauth2-proxy sits in front:

```
you → Traefik → oauth2-proxy ──> Keycloak realm `bytebase` ──> GitHub
                    │
                    └─ only if you are in the bytebase-admins group ─> Bytebase's own login
```

1. Keycloak → GitHub decides **whether you reach Bytebase at all**.
2. Bytebase's own local admin account is a second, separate login inside the app.

Bytebase never learns your Keycloak identity. See [FINDINGS.md](FINDINGS.md) for what that
costs and whether the Enterprise upgrade is worth it.

Verify the gate is working without a browser:

```bash
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' https://bytebase.kakde.eu/
```

Expect `302` and a redirect to `https://keycloak.kakde.eu/realms/bytebase/protocol/openid-connect/auth?...`.
If you get the Bytebase UI directly, the gate is bypassed — treat that as an incident.

### 1.2 Reaching everything else

Nothing except Bytebase is exposed publicly. Kafbat UI, RabbitMQ's management console and every
raw database port are ClusterIP-only, on purpose.

```bash
kubectl -n dblab port-forward svc/kafbat-ui 8081:8080     # then http://localhost:8081
kubectl -n dblab port-forward svc/rabbitmq 15672:15672    # then http://localhost:15672
kubectl -n dblab port-forward svc/postgres 15432:5432
kubectl -n dblab port-forward svc/mongodb 27017:27017
kubectl -n dblab port-forward svc/redis 6379:6379
kubectl -n dblab port-forward svc/elasticsearch 9200:9200
kubectl -n dblab port-forward svc/cassandra 9042:9042
kubectl -n dblab port-forward svc/dynamodb-local 8000:8000
```

### 1.3 Native clients, straight into the pods

Fastest way to check whether a problem is the database or the client. Each of these was run
successfully during verification.

```bash
# credentials helper — the lab passwords are generated, not committed
LAB() { kubectl -n dblab get secret dblab-credentials -o jsonpath="{.data.$1}" | base64 -d; }

# PostgreSQL
kubectl -n dblab exec -it deploy/postgres -- env PGPASSWORD="$(LAB postgres-password)" \
  psql -U "$(LAB postgres-user)" -d labdb

# MongoDB
kubectl -n dblab exec -it deploy/mongodb -- mongosh \
  "mongodb://$(LAB mongo-user):$(LAB mongo-password)@localhost:27017/labdb?authSource=admin"

# Redis
kubectl -n dblab exec -it deploy/redis -- redis-cli -a "$(LAB redis-password)" --no-auth-warning

# Cassandra
kubectl -n dblab exec -it deploy/cassandra -- cqlsh -u cassandra -p cassandra

# Elasticsearch (no auth — security is disabled)
kubectl -n dblab exec deploy/elasticsearch -- curl -s localhost:9200/products/_count

# Kafka
kubectl -n dblab exec deploy/kafka -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# RabbitMQ
kubectl -n dblab exec deploy/rabbitmq -- rabbitmqctl list_queues

# DynamoDB Local — its image has no AWS CLI, so use a throwaway pod
kubectl -n dblab run ddb --rm --restart=Never --attach --quiet --image=amazon/aws-cli:2.31.9 \
  --env AWS_ACCESS_KEY_ID=dummy --env AWS_SECRET_ACCESS_KEY=dummy --env AWS_DEFAULT_REGION=eu-central-1 \
  --command -- /bin/sh -c 'aws --endpoint-url http://dynamodb-local:8000 dynamodb scan --table-name Orders --select COUNT'
```

### 1.4 Registering instances in Bytebase — the table you actually need

Instance registration is UI-only on the free tier; it cannot be scripted. In Bytebase go to
**Instances → Add Instance** and use these values.

To print the whole matrix with the live passwords filled in:

```bash
deploy/apps/dblab/scripts/lab-credentials.sh --show
```

(without `--show` the passwords are masked, so the output is safe to paste into an issue)

> **The host is the Kubernetes Service DNS name.** Not `localhost`, not a node IP, not
> `192.168.15.x`. Bytebase resolves these from inside the cluster. Getting this wrong is the
> single most common failure, and the error it produces ("connection refused") looks exactly
> like a dead database.

| Engine | Host | Port | Username | Password |
|---|---|---|---|---|
| **PostgreSQL (production)** | `postgresql.databases-prod.svc.cluster.local` | 5432 | `bytebase` | `read-secret-value.sh bytebase bytebase-db managed-password` |
| PostgreSQL (lab) | `postgres.dblab.svc.cluster.local` | 5432 | `labadmin` | from `dblab-credentials` |
| MongoDB | `mongodb.dblab.svc.cluster.local` | 27017 | `labadmin` | from `dblab-credentials` |
| Redis | `redis.dblab.svc.cluster.local` | 6379 | *(blank)* | from `dblab-credentials` |
| Elasticsearch | `elasticsearch.dblab.svc.cluster.local` | 9200 | *(blank)* | *(blank)* |
| Cassandra | `cassandra.dblab.svc.cluster.local` | 9042 | `cassandra` | `cassandra` |
| DynamoDB Local | `dynamodb-local.dblab.svc.cluster.local` | 8000 | *(host + port only — see below)* | |

Free tier ceiling is **10 instances and 20 users**; the table above uses 7.

> **DynamoDB does not work end to end, and cannot be made to.** You can register the instance and
> `Test Connection` will pass — but **no database will ever appear**, so there is nothing to
> query or transfer into a project.
>
> `Test Connection` only runs `ListTables`. Sync is the step that matters, and
> `backend/plugin/db/dynamodb/sync.go` builds the pseudo-database name from
> `{account_id}-{region}` via an **AWS STS `GetCallerIdentity` call whose client has no endpoint
> override** — so it always goes to real AWS and is rejected with `InvalidClientTokenId`.
> DynamoDB Local cannot answer it either; it returns `InternalFailure` because it does not
> implement STS.
>
> Two related gaps, both verified: the DynamoDB instance form shows only host and port
> (`DataSourceForm.tsx` excludes `DYNAMODB` from both `showMainFields` and `showAuthTypeRadio`),
> so `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` are set on the Bytebase
> Deployment instead. That gets you past the IMDS timeout — but not past STS.
>
> **Use the AWS CLI for DynamoDB Local** (§1.3). It stays deployed and seeded because it is still
> useful that way. Bytebase coverage would need a real AWS account. Full analysis in
> [FINDINGS.md](FINDINGS.md) §2.1.

Kafka and RabbitMQ are deliberately absent — they are not databases and Bytebase does not
manage them. They also are not reachable from the `bytebase` namespace at all (verified), by
NetworkPolicy design.

### 1.5 Getting those databases into a project

Registering an instance is not enough, and the model catches people out:

```
Instance (a server connection) ──contains──> Database ──belongs to──> Project
                                                 │
Environment (Test / Prod) is set on the INSTANCE ┘ and inherited by its databases
```

An instance is never "in" a project. A **database** belongs to exactly one project, so a
transfer is a move rather than a copy.

1. **Instances** → select the instances → **Sync all databases**. (Bytebase syncs on a timer
   anyway; this just avoids waiting.) Newly discovered databases land as **Unassigned**.
2. **Projects → \<your project\> → Databases → Transfer in DB** → choose
   **Transfer unassigned databases** → tick them → **Transfer**.

> **Leave `bytebase_meta` Unassigned.** It is Bytebase's own metadata store — every instance
> registration, user and setting. Putting it under project management lets Bytebase propose
> schema changes against itself.

`keycloak` is safe to transfer despite being production: it is read-only (§5.1), so it browses
but refuses every write.

---

## 2. Users and access control

### 2.1 The one thing that controls access

Membership of the Keycloak group **`bytebase-admins`**. oauth2-proxy runs with
`--allowed-group=bytebase-admins`, so that group is exactly the set of people who can reach
Bytebase.

```bash
scripts/secrets/grant-bytebase-admin.sh --list             # who has access, and who is linked
scripts/secrets/grant-bytebase-admin.sh                    # grant ani2fun (the default)
scripts/secrets/grant-bytebase-admin.sh someone-else       # grant another GitHub handle
scripts/secrets/grant-bytebase-admin.sh --revoke someone   # take it away
```

Idempotent, and safe to run before someone's first login.

**Pass the GitHub handle as the username.** The IdP runs `syncMode: IMPORT`, so the Keycloak
username equals the GitHub handle — and the script uses that to look up their GitHub numeric id
and **link the federated identity at creation time**.

That linking is not cosmetic. Granting access to someone who has never signed in means creating
a placeholder account with no password and no linked identity; without the link, their first
GitHub sign-in stops dead at *"Account already exists"* with no working way forward (see the
symptom table in §6.4). The script warns loudly if it cannot resolve the id — e.g. no network —
and you can supply it by hand:

```bash
scripts/secrets/grant-bytebase-admin.sh --github-id 11439845 ani2fun
```

`--list` annotates every member so a stranded placeholder is visible before anyone hits it:

```
  ani2fun  [github linked]
  someone  [UNLINKED PLACEHOLDER — will hit 'Account already exists' on first GitHub login]
```

### 2.2 Which layers actually restrict anything

Worth being precise about, because one of the three commonly-assumed layers does nothing:

| Layer | Really restricts? |
|---|---|
| GitHub OAuth app | **No.** Any GitHub account can authorize an OAuth app. This is not a filter. |
| Keycloak `registrationAllowed: false` | Partly — blocks password self-signup, but first-broker-login still creates a user for any GitHub account that authenticates. |
| Keycloak group `bytebase-admins` | **Yes** — this is the policy. |
| oauth2-proxy `--allowed-group` | **Yes** — this is what enforces it on every request. |

So a stranger *can* end up with a `bytebase` realm account. They still cannot reach Bytebase.
If you ever see an unexpected user in the realm, that is not a breach — check group membership.

### 2.3 Verifying the lockdown still holds

This was verified end-to-end without a browser, using Keycloak's token evaluation endpoint
against the real `bytebase-proxy` client:

- with `ani2fun` in the group, the ID token contained `groups: ["bytebase-admins"]`
- with `ani2fun` removed, the claim was **absent entirely** — so `--allowed-group` refuses

To re-check after any realm change:

```bash
ssh ms-1 'ADMIN_U=$(kubectl -n identity get secret keycloak-admin-secret -o jsonpath="{.data.username}" | base64 -d)
ADMIN_P=$(kubectl -n identity get secret keycloak-admin-secret -o jsonpath="{.data.password}" | base64 -d)
kubectl -n identity exec -i deploy/keycloak -- /bin/sh -s -- "$(printf %s "$ADMIN_U"|base64)" "$(printf %s "$ADMIN_P"|base64)" <<"R"
kcadm=/opt/keycloak/bin/kcadm.sh
"$kcadm" config credentials --server http://127.0.0.1:8080 --realm master --user "$(printf %s "$1"|base64 -d)" --password "$(printf %s "$2"|base64 -d)" >/dev/null 2>&1
cid=$("$kcadm" get clients -r bytebase -q clientId=bytebase-proxy --fields id --format csv --noquotes | head -n1)
uid=$("$kcadm" get users -r bytebase -q username=ani2fun -q exact=true --fields id --format csv --noquotes | head -n1)
"$kcadm" get "clients/$cid/evaluate-scopes/generate-example-id-token?userId=$uid&scope=openid+email+profile" -r bytebase
R'
```

Look for `"groups": [ "bytebase-admins" ]` in the output. If that claim is missing, nobody can
log in — the group-membership protocol mapper on the `bytebase-proxy` client has been lost.

### 2.4 Bytebase's own admin account

Separate from Keycloak entirely. Created on first visit to the UI. Because only group members
can even reach the login page, this account is behind the Keycloak gate — but it is still a real
credential, so give it a strong password from your password manager.

If you are locked out of it, the account lives in the `bytebase_meta` database on the production
Postgres and can be reset there; it is not in any Kubernetes secret.

---

## 3. Secrets

Nothing sensitive is committed. Two sealed secrets and one generated-in-cluster secret.

| Secret | Namespace | Keys | Created by |
|---|---|---|---|
| `bytebase-oauth2-proxy` | `bytebase` | `client-id`, `client-secret`, `cookie-secret` | `seal-bytebase-secrets.sh` (sealed, in git) |
| `bytebase-db` | `bytebase` | `pg-url`, `managed-password` | `seal-bytebase-secrets.sh` (sealed, in git) |
| `bytebase-keycloak-github-oauth` | `identity` | `client-id`, `client-secret` | `sync-bytebase-github-idp.sh` (live, **not** sealed) |
| `dblab-credentials` | `dblab` | the lab passwords | `lab-up.sh` (generated, **not** in git) |

### 3.1 Reading a value back

```bash
scripts/secrets/read-secret-value.sh bytebase bytebase-db managed-password
kubectl -n dblab get secret dblab-credentials -o jsonpath='{.data.postgres-password}' | base64 -d
```

### 3.2 Rotating the oauth2-proxy / metadata secrets

`seal-bytebase-secrets.sh` reads the `bytebase-proxy` client secret **straight out of Keycloak**,
so you never copy-paste it:

```bash
scripts/secrets/seal-bytebase-secrets.sh                       # generates fresh DB passwords
scripts/secrets/seal-bytebase-secrets.sh <meta-pw> <managed-pw> # or supply your own
```

It writes both sealed secrets into `deploy/apps/bytebase/overlays/prod/`. **The passwords must
also be changed in Postgres or Bytebase will fail to start** — do both in one go:

```bash
kubectl -n databases-prod exec -it postgresql-0 -- sh -lc 'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U postgres'
```
```sql
ALTER ROLE bytebase_meta LOGIN PASSWORD '<meta-pw>';
ALTER ROLE bytebase      LOGIN PASSWORD '<managed-pw>';
```

Then `kubectl apply -k deploy/apps/bytebase/overlays/prod` and restart the deployment.

Order matters: seal first, then change Postgres, then apply. Changing Postgres first leaves
Bytebase unable to connect for the gap in between.

### 3.3 Rotating the Keycloak client secret

```bash
ssh ms-1 'kubectl -n identity exec deploy/keycloak -- /opt/keycloak/bin/kcadm.sh \
  create clients/<client-id>/client-secret -r bytebase'
```
Then re-run `seal-bytebase-secrets.sh` (it re-reads the new value automatically) and re-apply.

### 3.4 Rotating the GitHub OAuth app

```bash
scripts/secrets/sync-bytebase-github-idp.sh <new-client-id> <new-client-secret>
```
Run with no arguments to re-sync the IdP from the stored secret without changing credentials.

### 3.5 After a sealed-secrets key rotation

Existing SealedSecrets keep working (old keys are retained). To re-seal with the current key,
refresh the cert and re-run the seal script:

```bash
scripts/secrets/fetch-sealed-secrets-cert.sh /tmp/sealed-secrets-cert.pem
scripts/secrets/seal-bytebase-secrets.sh
```

---

## 4. Keycloak

### 4.1 Getting around the admin console

<https://keycloak.kakde.eu> → credentials from
`scripts/secrets/read-keycloak-admin-credentials.sh`.

The **realm switcher is the top-left dropdown** and it is the thing people miss — almost every
"my setting disappeared" turns out to be edits made in the wrong realm. Realms currently live:
`master`, `kakde`, `apps-prod`, `synapse`, `bytebase`.

Within the `bytebase` realm:

| Where | What is there |
|---|---|
| **Clients → bytebase-proxy** | The confidential client oauth2-proxy uses. Its **Credentials** tab has the client secret; its **Client scopes → Dedicated → Mappers** tab has the `groups` mapper. |
| **Groups → bytebase-admins** | The access policy. Its **Members** tab is the allowlist. |
| **Users** | Should contain only people who have signed in, plus anyone granted ahead of time. |
| **Identity providers** | The GitHub broker. |
| **Realm settings → Login** | `User registration` is off, deliberately. |

### 4.2 Adding a client for a future app

Use `bytebase-proxy` as the worked example — it is a standard confidential
authorization-code client. The parts that are easy to get wrong:

- **Valid redirect URIs** must match exactly, including the path. oauth2-proxy uses
  `https://<host>/oauth2/callback`.
- If the app needs group-based authorization, add an **oidc-group-membership-mapper** on the
  client with claim name `groups` and `full.path` off. Keycloak does **not** emit groups by
  default, and there is no built-in `groups` client scope — requesting one fails the whole
  authorization request with `invalid_scope`.
- Keep `description` under **255 characters**. Keycloak's `CLIENT.DESCRIPTION` column is
  `varchar(255)` and a longer one fails realm import with an opaque `Database operation failed`.

### 4.3 Export and re-import

```bash
REALM=bytebase scripts/dr/backup-keycloak-realm.sh
```
Writes `bytebase-realm-<timestamp>.json`, mode 0600, via the REST API (no downtime, unlike
`kc.sh export`). The committed starting point is
[keycloak-realm-prod.json](keycloak-realm-prod.json) — it contains the realm, the group, the
client and the mapper, but **no users and no client secret** (Keycloak generates that on import).

To import from scratch:

```bash
ssh ms-1 'kubectl -n identity exec -i deploy/keycloak -- /opt/keycloak/bin/kcadm.sh create realms -f -' \
  < deploy/apps/bytebase/keycloak-realm-prod.json
```

After importing, re-run `seal-bytebase-secrets.sh` (to capture the newly generated client
secret) and `grant-bytebase-admin.sh`.

---

## 5. Database operations

### 5.1 What Bytebase can touch on the production Postgres

Access is granted per database by **role membership**, so Bytebase inherits everything the owning
role can do — including on tables created later. Current state, verified:

| Database | Connect | Read | Write / DDL | How |
|---|---|---|---|---|
| `appdb`, `dsa_tracker`, `testdb` | yes | yes | yes | `GRANT appuser TO bytebase` |
| `synapse` | yes | yes | yes | `GRANT synapse TO bytebase` |
| `codefolio` | yes | yes | yes | `GRANT codefolio TO bytebase` |
| `keycloak` | yes | yes | **no — denied** | explicit `GRANT SELECT`, deliberately **not** membership |

Keycloak is read-only on purpose: it is the database that authenticates you *into* Bytebase, so
a bad migration there would lock you out of Bytebase, Grafana, Synapse and the Keycloak console
at once. Verified 2026-08-10 — `SELECT` returns rows, while `INSERT`, `UPDATE`, `DELETE` and
`CREATE TABLE` are all refused.

Never use `GRANT keycloak TO bytebase`. Role membership inherits ownership, which is full write
access — the opposite of what is wanted here.

> **A nuance worth knowing.** PostgreSQL grants `CONNECT` on every database to `PUBLIC` by
> default, so `bytebase` *can open a connection* to `keycloak` — that is not a misconfiguration
> and not something the grants above control. What protects Keycloak is table and schema
> privileges, which were verified to deny both `SELECT` and `CREATE`.

`bytebase` is **not** a superuser (verified `rolsuper = f`), so it cannot touch `pg_authid`,
create roles, or read server files.

### 5.2 Granting another database

```sql
GRANT <owner-role> TO bytebase;   -- full DDL+DML on everything that role owns, now and later
```

`permission denied for table X (SQLSTATE 42501)` in Bytebase means exactly this grant is
missing for whichever database `X` lives in. Find the owner with:

```sql
SELECT datname, pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datistemplate = false;
```

Membership only applies if the member role inherits — `bytebase` was created with the default
`rolinherit = t`. A `NOINHERIT` role makes membership grants appear to do nothing at all.

Think before adding `keycloak`: it is the database that authenticates you *into* Bytebase. A bad
migration there locks you out of Bytebase, Grafana, Synapse and the Keycloak console
simultaneously. If you genuinely need visibility, grant read-only instead:

```sql
\c keycloak
GRANT USAGE ON SCHEMA public TO bytebase;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO bytebase;
```

### 5.3 Revoking

```sql
REVOKE synapse FROM bytebase;
```

### 5.4 Backups

`scripts/dr/postgres-backup.sh` enumerates databases at run time
(`SELECT datname FROM pg_database`), so `bytebase_meta` — which holds every registered instance,
user and setting — is backed up automatically with no script change. That is precisely why the
metadata lives on the shared Postgres rather than in its own container.

---

## 6. Lifecycle

### 6.1 The lab

```bash
deploy/apps/dblab/scripts/lab-up.sh       # create + wait + seed. Idempotent.
deploy/apps/dblab/scripts/lab-verify.sh   # pass/fail table, non-zero exit on failure
deploy/apps/dblab/scripts/lab-stop.sh     # scale to 0 — frees ~4 GiB, keeps all data
deploy/apps/dblab/scripts/lab-nuke.sh     # delete namespace + PVCs + data. Asks first.
```

Which to use:

- **stop** when you want the RAM back but expect to come back to the same data. Restart is
  seconds and needs no re-seeding.
- **nuke** when you want the disk back or a guaranteed-clean slate. Rebuilding takes a few
  minutes, almost all of it Cassandra.

**The lab stops itself after 4 hours.** `lab-up.sh` records an absolute deadline in the
`dblab-lifecycle` ConfigMap and the `dblab-autostop` CronJob scales everything to zero once it
passes (checked every 15 min). Only scale-to-zero is ever automated — PVCs and seed data are
never touched on a timer.

```bash
LAB_TTL_HOURS=8 deploy/apps/dblab/scripts/lab-up.sh   # longer session
kubectl -n dblab delete configmap dblab-lifecycle     # disable for this session
kubectl -n dblab logs -l app.kubernetes.io/name=dblab-autostop --tail=20   # what it decided
```

If the lab is unexpectedly at `0/0`, this is the first thing to check — it is far more likely
than a crash.

Stopping or nuking the lab does **not** affect Bytebase. Instances you registered will simply
show as unreachable until it comes back.

### 6.2 Bytebase

Currently applied by hand:

```bash
kubectl apply -k deploy/apps/bytebase/overlays/prod
```

Once `deploy/apps/bytebase/` is committed and pushed, apply
`deploy/platform/argocd/applications/bytebase.yaml` and Argo takes over with `selfHeal` and
`prune`. **Do not apply that Application before the push** — it would sit permanently degraded
pointing at a path that does not exist in git.

### 6.3 Troubleshooting, bottom-up

Work in this order; a failure low down makes everything above it look broken.

1. **WireGuard / node health** — `ssh ms-1 'kubectl get nodes -o wide'`
2. **Pods** — `ssh ms-1 'kubectl -n dblab get pods'`, `... -n bytebase get pods`
3. **Traefik** — `ssh ms-1 'kubectl -n traefik logs deploy/traefik --tail=50 | grep bytebase'`
4. **TLS** — `ssh ms-1 'kubectl -n bytebase get certificate,order'`
5. **Keycloak** — `curl -sI https://keycloak.kakde.eu/realms/bytebase/.well-known/openid-configuration`
6. **oauth2-proxy** — `ssh ms-1 'kubectl -n bytebase logs deploy/bytebase-oauth2-proxy --tail=50'`
7. **Bytebase** — `ssh ms-1 'kubectl -n bytebase logs deploy/bytebase --tail=50'`
8. **Engines** — `deploy/apps/dblab/scripts/lab-verify.sh`

### 6.4 Known symptoms

| Symptom | Cause | Fix |
|---|---|---|
| Traefik **504** after exactly 30s on `bytebase.kakde.eu` | NetworkPolicy is dropping Traefik. Traefik runs `hostNetwork: true` on ctb-edge-1, so its traffic arrives from that node's Calico VXLAN tunnel address — a `namespaceSelector` can never match it. | The `ipBlock: 10.42.0.0/16` rule in `base/networkpolicy.yaml` handles this. Do not "simplify" it back to a namespaceSelector. |
| Traefik **404** on HTTPS although the cert is valid | Missing `traefik.ingress.kubernetes.io/router.tls: "true"` | Add the annotation. All three Traefik markers are required in this cluster. |
| Kafka pod stuck `0/1` forever, log says `Kafka Server started` | Two separate causes, both hit during this build: (a) probe `timeoutSeconds` defaults to **1s** and every `kafka-*.sh` helper is a JVM tool that cannot start that fast; (b) the broker advertises its Service DNS name, but a Service has no endpoints until the pod is Ready — a deadlock. | Explicit `timeoutSeconds: 15` on the probes, and `publishNotReadyAddresses: true` on the Kafka Service. Both are in `base/kafka.yaml` with comments. |
| Any exec-probe container restart-looping | Same 1s default timeout. `cqlsh` (Python) and `mongosh` (Node) are both too slow for it. | Set `timeoutSeconds` explicitly on every exec probe. |
| PVC stuck `Pending` | `local-path` is `WaitForFirstConsumer` and node-local; the pod is not pinned to wk-1. | Every workload here sets `nodeSelector: kubernetes.io/hostname: wk-1`. |
| Bytebase says "connection refused" for a lab engine | Host was set to `localhost` or a node IP. | Use the Service DNS name from §1.4. |
| oauth2-proxy redirect loop | `--redirect-url` does not match the Keycloak client's Valid Redirect URI exactly. | Both must be `https://bytebase.kakde.eu/oauth2/callback`. |
| Login succeeds at GitHub then oauth2-proxy returns 403 | User is not in `bytebase-admins`, or the `groups` mapper is gone. | §2.1 and §2.3. |
| Keycloak shows **"Account already exists — User with username X already exists"** after GitHub | X was granted access *before* ever signing in, so they have a placeholder Keycloak account with no password and no linked identity. **Neither button on that screen can succeed**: "Add to existing account" verifies by email (needs SMTP — this realm has none) and the fallback wants a password the placeholder does not have. | Re-run `grant-bytebase-admin.sh <handle>`; it links the GitHub identity in place and the next sign-in goes straight through. `--list` flags unlinked placeholders before anyone walks into this. |
| Elasticsearch won't start after a wk-1 rebuild | `vm.max_map_count` back at the 65530 default. | See the note in `deploy/bootstrap/host-prep/sysctl/`. |

---

## 7. Still to do

These are the only steps that could not be completed without you.

### 7.1 Create the GitHub OAuth app

The realm currently has **no identity provider**, and `ani2fun` has no password — so nobody can
log in at all until this is done.

Go to **GitHub → Settings → Developer settings → OAuth Apps → New OAuth App**
(<https://github.com/settings/developers>).

> Pick **OAuth Apps**, not **GitHub Apps**. They sit next to each other in that menu and are
> different products — a GitHub App uses a different flow that Keycloak's `github` provider does
> not speak.

| Field | Value |
|---|---|
| Application name | `Bytebase (kakde.eu)` — free text |
| Homepage URL | `https://bytebase.kakde.eu` |
| Application description | optional |
| **Authorization callback URL** | `https://keycloak.kakde.eu/realms/bytebase/broker/github/endpoint` |
| Enable Device Flow | leave unchecked |

**The callback URL points at Keycloak, not at Bytebase.** Keycloak is the party that talks to
GitHub; Bytebase never does — it only ever sees the outcome, through oauth2-proxy. Setting this
to a `bytebase.kakde.eu` URL fails with a redirect_uri mismatch.

A GitHub OAuth app carries exactly one callback URL, so this realm needs its **own** app; the
`synapse` and `apps-prod` apps cannot be reused.

After **Register application**, copy the **Client ID**, then **Generate a new client secret** and
copy it straight away — GitHub displays it once.

### 7.2 Wire it into Keycloak

```bash
scripts/secrets/sync-bytebase-github-idp.sh <client-id> <client-secret>
```

Stores the credentials as `bytebase-keycloak-github-oauth` in the `identity` namespace, then
creates the IdP with `kcadm`. Re-run with no arguments any time to re-sync from the stored secret.

Needs a working `kubectl` — see §0 if the tunnel and kubeconfig ports disagree.

Confirm before opening a browser:

```bash
scripts/secrets/grant-bytebase-admin.sh --list      # expect: ani2fun
```

`syncMode: IMPORT` makes the Keycloak username equal the GitHub handle, so signing in as
`ani2fun` links to the account already in the group rather than creating a second one.

### 7.3 First login

<https://bytebase.kakde.eu> → Keycloak → **Sign in with GitHub** → back to Bytebase.

You then land on Bytebase's own **Setup admin account** page at `/auth/signup`. That is expected,
not a misconfiguration — it is the second of the two logins described in §1.1. Reaching it means
the whole gate worked: GitHub authenticated you, Keycloak issued a token carrying
`groups: ["bytebase-admins"]`, and oauth2-proxy admitted you.

Fill it in with a real email, a strong password from your password manager, and username
`ani2fun`. It is a one-time screen; `/auth/signup` is not reachable afterwards. This local
account is the only Bytebase identity, and it is safe behind the Keycloak gate — nobody outside
`bytebase-admins` can reach the page at all.

### 7.4 Then

1. **Register the instances** from the table in §1.4.
2. **Confirm the SQL editor works through oauth2-proxy** — it may use websockets, which is
   **NOT YET VERIFIED**.
3. **Answer the Redis / Cassandra question** in [FINDINGS.md](FINDINGS.md) §6 — that is the
   point of the whole exercise and the one thing still open.
