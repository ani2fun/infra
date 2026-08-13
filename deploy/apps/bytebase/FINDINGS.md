# Bytebase evaluation — findings

Written 2026-08-10, after building and deploying the stack. The purpose of the exercise was to
decide whether Bytebase should become the standard database client here.

Anything marked **NOT VERIFIED** could not be tested without a browser session, which needs the
GitHub OAuth app that does not exist yet (see [OPERATIONS.md §7](OPERATIONS.md)). Those gaps are
stated rather than papered over.

---

## 1. The headline: SSO is not available on the free tier

**Bytebase's OIDC SSO is an Enterprise-plan feature.** The
[pricing table](https://www.bytebase.com/pricing/) lists SSO as:

| Community | Pro | Enterprise |
|---|---|---|
| — | Google, GitHub | OAuth2, OIDC, LDAP |

This is worth flagging loudly because **the OIDC documentation page carries no plan badge at
all** — nothing on <https://docs.bytebase.com/administration/sso/oidc/> indicates the feature is
paid. Reading only the docs, you would build the whole integration before discovering it does not
work. The restriction is only visible on the pricing page.

Self-hosted free instances can activate a **14-day Enterprise trial** (Settings → Subscription),
so native Keycloak OIDC can be evaluated properly before committing money. That has not been done
yet — the trial clock is worth saving until there is a reason to start it.

### What was built instead

oauth2-proxy in front of Bytebase, authenticating against a dedicated Keycloak realm. This is
the same pattern the retired `whoami-auth.kakde.eu` demo used (recoverable at
`git show 36d9411^:deploy/apps/whoami/base/oauth2-proxy-deployment.yaml`).

**Verified working:** `https://bytebase.kakde.eu/` returns `302` to
`keycloak.kakde.eu/realms/bytebase/protocol/openid-connect/auth` with PKCE (`code_challenge_method=S256`)
and the correct `redirect_uri`.

**The cost, stated plainly:** there are two logins. Keycloak/GitHub decides whether you reach
Bytebase; Bytebase's own local account is a separate credential behind it. Bytebase never learns
your Keycloak identity, so its internal RBAC (Workspace Admin / DBA / Developer), audit trail and
per-user attribution are all blind to who you actually are. For a single-operator homelab that is
tolerable. For a team it would not be — the audit log would show one shared account.

**The full chain is now confirmed in a real browser** (2026-08-10): GitHub authenticated,
Keycloak issued a token carrying `groups: ["bytebase-admins"]`, oauth2-proxy admitted the
request, and Bytebase served its own first-run signup page. So the gate genuinely works
end to end, not just at the redirect level.

### The lockdown was verified without a browser

Using Keycloak's token-evaluation endpoint against the real `bytebase-proxy` client:

- `ani2fun` **in** `bytebase-admins` → ID token contains `groups: ["bytebase-admins"]`
- `ani2fun` **removed** → the claim is **absent entirely**, so `--allowed-group` refuses

One correction to an easy assumption: **the GitHub OAuth app is not an access control.** Any
GitHub account can authorize an OAuth app, and first-broker-login will create a realm user for
them. The Keycloak group plus oauth2-proxy's `--allowed-group` are what actually gate access.

---

## 2. The three risky unknowns — all resolved from source

The brief flagged three items to resolve empirically. Rather than guessing through the UI, they
were answered by reading Bytebase's driver code, which is faster and gives an exact answer.

### 2.1 DynamoDB Local — **Bytebase cannot manage it. This needs a real AWS account.**

The brief called this the highest-risk item and asked for a clear verdict rather than a
workaround that hides a limitation. The verdict: **it does not work**, and the reason is
structural rather than configuration.

Three separate layers, with three different answers:

| Layer | Result |
|---|---|
| Endpoint override in the driver | ✅ supported |
| Connection test (`Ping` → `ListTables`) | ✅ passes |
| **Database sync (`SyncInstance`)** | ❌ **fails — requires real AWS credentials** |

`Test Connection` succeeding is misleading: it only proves `ListTables` works. Sync is the step
that matters, and it fails.

**The endpoint override is genuinely supported.**
`backend/plugin/db/dynamodb/dynamodb.go` derives a custom base endpoint from the data source:

```go
func dynamoDBEndpoint(ds *storepb.DataSource) string {
    host := ds.GetHost()
    if host == "" {
        return ""          // fall back to real AWS endpoint resolution
    }
    ...
    return fmt.Sprintf("%s://%s:%s", scheme, host, port)   // http:// unless Use SSL
}
```

So setting host `dynamodb-local.dblab.svc.cluster.local` and port `8000` is supported behaviour,
not a workaround.

**But the UI cannot supply credentials for DynamoDB at all.** Registering the instance failed with:

```
invalid datasource ADMIN: failed to list dynamodb tables: operation error DynamoDB: ListTables,
get identity: get credentials: failed to refresh cached credentials, no EC2 IMDS role found,
operation error ec2imds: GetMetadata, request canceled, context deadline exceeded
```

Not a networking problem — it reached `ListTables` and failed resolving credentials. The cause is
in `frontend/src/components/instance/DataSourceForm.tsx`:

```js
const showMainFields = engine !== SPANNER && engine !== BIGQUERY
                    && engine !== DYNAMODB && engine !== DATABRICKS;   // no username/password
const showAuthTypeRadio = MYSQL || POSTGRES || COSMOSDB || MSSQL || ELASTICSEARCH;  // no DYNAMODB
{isAwsIAM && ( /* the Region input */ )}                               // unreachable for DynamoDB
```

The DynamoDB form renders **only host and port**. There is no field for a region, an access key
or a secret — so `GetAWSConnectionConfig` finds no static credentials, falls through to the AWS
default chain, and dies at EC2 instance metadata, which does not exist in Kubernetes.

**Workaround applied:** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_REGION` are set on
the Bytebase Deployment. Those are the documented first step of the same default chain, so the
SDK picks them up. (`config.WithRegion("")` is ignored by the SDK rather than overriding
`AWS_REGION`, which is why setting the region there works.)

That is a legitimate configuration path rather than a hack — but it is **instance-wide**. Every
AWS data source in this Bytebase shares those credentials, and there is no way to fix that from
the UI.

**And it is not enough, because sync needs a real AWS identity.**

DynamoDB has no concept of a database, so `backend/plugin/db/dynamodb/sync.go` invents one:

```go
// DynamoDB do not have the concept of Database, which is important concept in Bytebase.
// We use the format {account_id}-{region} as the pseudo database name.
stsClient := sts.NewFromConfig(d.awsConfig)
identity, err := stsClient.GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
```

Note what is missing: the STS client is built from `d.awsConfig` with **no endpoint override** —
that is applied only to the DynamoDB client. So `GetCallerIdentity` always goes to real AWS.
Tested from inside the cluster with the dummy credentials:

```
aws sts get-caller-identity
  → An error occurred (InvalidClientTokenId): The security token included in the request is invalid.

aws --endpoint-url http://dynamodb-local.dblab.svc.cluster.local:8000 sts get-caller-identity
  → {"__type":"...#InternalFailure", ...}      # DynamoDB Local does not implement STS

aws --endpoint-url http://dynamodb-local...:8000 dynamodb list-tables
  → {"TableNames": ["Orders"]}                 # the data is right there, and unreachable
```

Real AWS STS *is* reachable from the cluster, so this is not a network restriction — the dummy
credentials are simply rejected, `SyncInstance` errors, and **no database is ever created**.
Without a database there is nothing to browse, query, or transfer into a project.

**No workaround was applied.** Options considered and rejected:

- *Point STS somewhere else* — nothing in this lab implements STS. LocalStack would, but adding
  a second emulator to satisfy one metadata call is not proportionate.
- *Supply real AWS credentials* — this would actually work, and is worth knowing: valid keys make
  `GetCallerIdentity` succeed, while the endpoint override still routes the DynamoDB calls to the
  local emulator. But it requires an AWS account, which defeats the point of testing locally.

**Verdict — matching what the brief anticipated: Bytebase's DynamoDB coverage requires a real AWS
account.** DynamoDB Local stays deployed and seeded (24 items in `Orders`) because it remains
useful via the AWS CLI, but it cannot be exercised through Bytebase.

More broadly, DynamoDB support here is visibly less finished than the other engines: the engine is
advertised as supported, its connection form is missing the fields its own driver requires, and
its sync path has a hard dependency on a service the documented "supported" configuration cannot
provide. Treat DynamoDB in Bytebase as second-class.

### 2.2 Cassandra — PasswordAuthenticator is required

`backend/plugin/db/cassandra/cassandra.go` sets the authenticator **unconditionally**:

```go
cluster.Authenticator = gocql.PasswordAuthenticator{
    Username: config.DataSource.Username,
    Password: config.Password,
}
```

So the default `AllowAllAuthenticator` would leave the connection form's credentials meaningless.
Cassandra now runs with `PasswordAuthenticator` + `CassandraAuthorizer`.

The official image exposes no `CASSANDRA_AUTHENTICATOR` env var, so `cassandra.yaml` is patched
by a `sed` before the entrypoint runs. **A caution from the brief did not apply:** `cassandra:5`
still uses the flat `authenticator: AllowAllAuthenticator` form, not the nested
`authenticator: {class_name: ...}` variant, so a one-line sed is correct — verified against the
image directly. Re-check if the tag is ever bumped.

### 2.3 Elasticsearch — security can stay off

`backend/plugin/db/elasticsearch/elasticsearch.go` attaches the basic-auth header only when a
credential exists (*"Only add basic auth header if it exists"*). So `xpack.security.enabled=false`
connects fine, and the simplest option is also the correct one for a throwaway lab. No bootstrap
password, no enrolment tokens.

---

## 3. What actually broke during the build

Three real problems, none of which were in the plan. All are now fixed in the manifests with
explanatory comments, and all are in [OPERATIONS.md §6.4](OPERATIONS.md).

### 3.1 Traefik 504 — NetworkPolicy vs hostNetwork

The default-deny policy allowed ingress from the `traefik` namespace via `namespaceSelector`.
That never matches: **Traefik runs `hostNetwork: true` on ctb-edge-1**, so its traffic arrives
from that node's Calico VXLAN tunnel address (`10.42.102.128`), not from a pod in the traefik
namespace. Every request became a Traefik 504 after exactly 30 seconds.

Fixed with an `ipBlock: 10.42.0.0/16` rule. The pod CIDR is used rather than pinning the tunnel
address because Calico reassigns those on node rejoin — a policy that breaks on rebuild is worse
than a slightly broad one. Breadth is acceptable specifically here because the endpoint is an
authentication gate already facing the internet; the rule that protects data is the separate
"only oauth2-proxy may reach Bytebase" policy.

**Note for the repo:** `postgresql-allow-from-ms1-host` and `postgresql-allow-from-wk1-host`
existed in the live cluster but **not in any file under `deploy/`** — someone had already hit
this exact class of problem for Postgres and fixed it out-of-band. Reconciled in Aug 2026:
`postgresql-allow-from-wk1-host` is now tracked in `deploy/platform/postgresql/5-networkpolicy.yaml`,
and `postgresql-allow-from-ms1-host` was measured to be a no-op for the same reason described
above — ms-1 does not host the Postgres pod, so its traffic also arrived from a VXLAN tunnel
address — and was deleted from both the cluster and Git rather than tracked.

### 3.2 Kafka stuck 0/1 forever — two independent bugs

The log cheerfully said `Kafka Server started` while the pod never became ready. Two causes,
which had to be untangled one at a time:

1. **A readiness deadlock.** The broker advertises `kafka.dblab.svc.cluster.local:9092`. Any real
   client — including the probe — connects to bootstrap, receives that advertised address, and
   reconnects to it. But a Service only routes to *ready* pods, so before the probe passes the
   ClusterIP has no endpoints and the reconnect fails with `DisconnectException`. The probe can
   never pass. Fixed with `publishNotReadyAddresses: true`.

2. **`timeoutSeconds` defaults to 1 second.** Every `kafka-*.sh` helper is a JVM program that
   cannot reach `main()` that fast, so the probe was killed before it could succeed — 10 container
   restarts before this was spotted. Run by hand the same command passed instantly, which is what
   gave it away.

The second bug affected more than Kafka: `cqlsh` (Python) and `mongosh` (Node) are also far too
slow for a 1s timeout. **Every exec probe in the lab now sets `timeoutSeconds` explicitly.** This
is the single most transferable lesson here — the default is a trap for any non-trivial CLI.

### 3.3 Granting access before first login strands the account

The very first real GitHub login stopped at Keycloak's *"Account already exists — User with
username ani2fun already exists"*.

Cause: `grant-bytebase-admin.sh` pre-created the realm user so that group membership would be in
place before the first sign-in. That placeholder had no password, no email and no linked
federated identity — so first-broker-login saw a username collision and demanded proof of
ownership. **Both offered routes were closed:** "Add to existing account" verifies by email,
which needs SMTP (the realm's `smtpServer` is `{}`), and the re-authentication alternative wants
a password the placeholder never had.

Fixed by linking the GitHub identity to the existing account
(`users/<id>/federated-identity/github` with the GitHub numeric id `11439845`), which removes the
collision rather than trying to resolve it. The login then completed straight through to
Bytebase's own signup page.

`grant-bytebase-admin.sh` now resolves the GitHub numeric id from the public API and links the
identity **at creation time**, so the trap cannot be re-armed; `--list` annotates every member
with `[github linked]` / `[UNLINKED PLACEHOLDER]` so a stranded account is visible before someone
walks into it.

Worth generalising: *any* Keycloak realm that grants access ahead of a user's first brokered
login has this problem, and it is invisible until someone tries. If SMTP is ever configured on
this Keycloak, the "verify by email" route would start working and this becomes far less sharp.

### 3.4 `--allowed-groups` does not exist

oauth2-proxy v7.15.3 has `--allowed-group`, **singular and repeatable**. The plural form makes
the process exit immediately. Similarly, requesting a `groups` OAuth scope fails with
`invalid_scope` — Keycloak ships no such scope, so the claim must come from a
group-membership protocol mapper defined on the client itself.

---

## 4. Resource usage

`kubectl top`, full lab plus Bytebase running idle after seeding:

| Node | CPU | Memory |
|---|---|---|
| wk-1 (everything lives here) | 346m / 1% | **6189Mi / 19%** of 30 GiB |

| Pod | CPU | Memory |
|---|---|---|
| elasticsearch | 4m | 1443Mi |
| cassandra | 50m | 1291Mi |
| kafka | 16m | 475Mi |
| kafbat-ui | 2m | 207Mi |
| dynamodb-local | 3m | 150Mi |
| rabbitmq | 88m | 130Mi |
| mongodb | 53m | 117Mi |
| postgres | 10m | 22Mi |
| redis | 3m | 4Mi |
| **dblab total** | | **≈ 3.8 GiB** |
| bytebase | 3m | 296Mi |
| bytebase-oauth2-proxy | 1m | 6Mi |

Comfortably within wk-1's headroom, and well under the ~10 GiB of *limits* configured. Elasticsearch
and Cassandra together are 71% of the footprint — if RAM ever gets tight, those two are the lever.
`lab-stop.sh` reclaims all of it in seconds.

CPU is a rounding error at idle (1% of the node), so this stack costs memory, not compute.

---

## 5. Verification results

`deploy/apps/dblab/scripts/lab-verify.sh`, using each engine's **native** client — never through
Bytebase, so a failure distinguishes a broken database from a broken client:

```
  PASS  postgres      orders rowcount        (40)
  PASS  mongodb       orders documents       (30)
  PASS  redis         dbsize                 (28)
  PASS  elasticsearch products count         (30)
  PASS  cassandra     orders_by_customer     (20)
  PASS  dynamodb      Orders item count      (24)
  PASS  kafka         seeded topics          (2)
  PASS  rabbitmq      declared queues        (2)
```

Cross-namespace connectivity from the `bytebase` namespace:

```
  OK       postgres.dblab:5432        OK       cassandra.dblab:9042
  OK       mongodb.dblab:27017        OK       dynamodb-local.dblab:8000
  OK       redis.dblab:6379           OK       postgresql.databases-prod:5432
  OK       elasticsearch.dblab:9200
  BLOCKED  kafka.dblab:9092           BLOCKED  rabbitmq.dblab:5672   (both correct)
```

The two BLOCKED lines matter: they prove the NetworkPolicy is genuinely enforcing rather than
being a permissive no-op.

### The stop / start cycle was exercised end to end

Because "spin it up and down whenever I want" was the actual requirement, the full cycle was run
rather than assumed:

1. `lab-stop.sh` → all 9 deployments to `0/0`, all 8 PVCs retained. **wk-1 memory dropped
   6189Mi → 2356Mi**, i.e. the measured 3.8 GiB came straight back.
2. `lab-up.sh` → all 9 engines ready, all 8 seed Jobs re-run, exit code 0.
3. `lab-verify.sh` → **every count identical to before the stop** (40 / 30 / 28 / 30 / 20 / 24 /
   2 / 2). Nothing was duplicated, which is the real test of whether the seed scripts are
   genuinely idempotent rather than merely re-runnable.

Bytebase was unaffected throughout — 0 restarts, and the Keycloak redirect still returned 302.
The two lifecycles really are independent.

One bug was found and fixed by doing this: `lab-stop.sh` originally waited on `pod --all`, which
includes the seed Jobs' Completed pods. Those are never deleted, so the wait always burned its
full 180s timeout. It is now scoped to exclude `component=seed`.

Production Postgres privileges, verified directly:

| Database | Connect | Read | Create |
|---|---|---|---|
| `appdb` etc. (granted via `appuser`) | yes | yes | yes |
| `keycloak` | yes | **denied** | **denied** |
| `synapse` | yes | no tables visible | — |

`bytebase` is **not** a superuser (`rolsuper = f`). One nuance found in testing: PostgreSQL grants
`CONNECT` on every database to `PUBLIC` by default, so `bytebase` *can* open a connection to
`keycloak` — that is normal Postgres behaviour, not a misconfiguration. Table and schema
privileges are what protect it, and those were confirmed to deny both reads and writes.

---

## 6. Redis and Cassandra query experience — ANSWERED

Exercised in the browser on 2026-08-10 against the seeded lab. The two engines land in very
different places, and the answer for one of them is not close.

The SQL editor works fine through oauth2-proxy — no websocket problem, queries return in 4–9 ms.

### 6.1 Redis — thin. Worse than `redis-cli`.

**The schema browser is literally empty.** Connect to a Redis database and the object panel
shows `<Empty>`. No keys, no key types, no namespace tree — nothing. There is no browsing at
all; you must already know what keys exist.

**Every reply collapses into a single `Value` column of stringified Go.** Not "types are hard to
read" — the type structure is discarded entirely:

| Command | What Bytebase shows |
|---|---|
| `HGETALL customer:1` | `map[country:NL email:customer1@example.invalid name:Customer 1 orders:4]` |
| `ZRANGE top_customers 0 4 WITHSCORES` | `[Customer 14 18]`, `[Customer 1 37]`, … |

The hash is Go's `fmt` map representation in one cell — no field/value columns, and a field
containing a space would be genuinely ambiguous. The sorted set fuses member and score into one
bracketed string, so scores cannot be sorted, filtered or read as numbers.

`redis-cli` does better than this: it at least prints hash fields on alternate lines and scores
separately. The web UI is strictly a downgrade on output, offering only a browser tab in exchange.

The seed data was built to expose exactly this — strings, three hashes, a list, a set, a sorted
set and a TTL key. **The type variety is invisible in the UI.**

Separately, Redis's 16 logical databases each appear as their own entry in the database picker,
burying the one that has data. Mitigated by capping the engine at `--databases 2`
(deploy/apps/dblab/base/redis.yaml), but note Bytebase caches the list — an instance sync is
required before the stale db2–db15 entries disappear.

### 6.2 Cassandra — genuinely good, with two small gaps

Everything that matters works:

- **Schema browser is real**: `Tables → orders_by_customer → Columns`, with accurate CQL types —
  `int`, `text`, `timestamp`, `decimal`, and **`list<text>` shown correctly** rather than
  flattened to a string.
- **Results are properly columnar**, one column per projected field.
- **Collections render as JSON**: `["SKU-0004","SKU-0005","SKU-0006"]`.
- **`decimal` keeps its precision** — `480.60`, not a mangled float. Worth checking explicitly,
  since decimal-to-float is a common silent corruption in database UIs.
- **Clustering order is preserved** — rows come back `order_id DESC` within each partition, which
  is what the table declares.

Two gaps, neither fatal:

1. **Partition and clustering keys are indistinguishable.** `customer_id` (partition) and
   `order_id` (clustering) both get the same generic key icon. For Cassandra that distinction is
   the single most important thing about a table — it determines what queries are possible — and
   the UI does not convey it.
2. **No warning on an unbounded partition scan.** `SELECT ... FROM orders_by_customer` with no
   `WHERE` ran silently; on a real multi-node cluster that is a full scan. Bytebase does apply
   its own 1000-row limit, which caps the damage but does not teach the anti-pattern.

Also cosmetic: table metadata reports `Row count estimate 0`, `Data size 0 B` for a table with 20
rows — Cassandra does not expose those cheaply, so the panel shows zeros rather than omitting them.

### 6.3 Verdict

**Cassandra: yes.** The schema browser and result rendering are good enough to use as a daily
client. Know that the key-type distinction is not shown and that nothing stops you writing a
cluster-wide scan.

**Redis: no.** Bytebase adds nothing over `redis-cli` and actively loses formatting. There is no
key browsing, and typed data is reduced to stringified Go. Keep using `redis-cli` (recipe in
[OPERATIONS.md §1.3](OPERATIONS.md)); register Redis in Bytebase only if having every engine in
one list is worth more than usable output.

That pattern — excellent for SQL-shaped engines, thin for the rest — is the honest summary of
Bytebase here. Postgres and Cassandra are well served; Redis is a checkbox; DynamoDB (§2.1)
does not work at all.

---

## 7. Verdict so far

**On the infrastructure: it works, and it was less trouble than expected.** All six engines plus
the messaging layer run comfortably on one node, every engine connects, and the three "risky
unknowns" from the brief all resolved favourably — DynamoDB Local in particular, which was
expected to be the blocker and simply works.

**On Bytebase as the standard client: not yet answerable, and the licensing changes the question.**
The free tier gives 10 instances and 20 users, which is plenty here. But no SSO means:

- identity stops at the front door; Bytebase itself has one shared local account
- its audit log cannot attribute anything to a real person
- adding a second operator means sharing a password, not granting access

For a single operator that is a reasonable trade. The moment a second person needs access, the
honest options are Enterprise or a different tool. Worth running the 14-day trial before deciding
— but start it when there is time to evaluate properly, not now.

**Recommendation:** adopt it as the standard client for the SQL-shaped engines — Postgres and
Cassandra are well served (§6). Do not treat it as a universal client: Redis is worse than
`redis-cli`, and DynamoDB does not work at all against a local endpoint. Revisit the Enterprise
question only if a second user ever needs access.
