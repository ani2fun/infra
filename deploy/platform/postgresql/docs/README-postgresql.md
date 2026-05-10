# PostgreSQL (`databases-prod`)

This directory contains the manifests and operating notes for a **single-instance PostgreSQL deployment** for internal Kubernetes use only.

## Overview

This PostgreSQL deployment is designed for the current Homelab-0 cluster:

- Kubernetes: **K3s**
- CNI: **Calico VXLAN**
- Nodes:
  - `ms-1` = K3s server
  - `wk-1`, `wk-2`, `ctb-edge-1` = agents
- Public ingress: **Traefik on `ctb-edge-1` only**
- This PostgreSQL instance is **not exposed publicly**

## Design goals

- Internal cluster access only
- Simple, explicit, and reversible deployment
- Persistent storage with **80Gi** PVC
- Dedicated database namespace
- Secret-based credentials
- Safe default network exposure model

## Important design notes

### 1. Internal only
This PostgreSQL instance must **not** be exposed to the internet.

That means:

- **No Ingress**
- **No LoadBalancer Service**
- **No NodePort Service**
- Only a **ClusterIP Service** for internal access

### 2. Storage model
This deployment uses the K3s default storage class:

- `local-path`

This means the data is stored on the local disk of the node that runs the PostgreSQL pod.

For this setup, PostgreSQL is pinned to a node labeled:

- `kakde.eu/postgresql=true`

Recommended node:

- `wk-1`

Implication:

- this is a **single-node storage model**
- if that node is lost, the database does **not** automatically fail over with the same data
- backups are therefore important

### 3. Bootstrap behavior
The init ConfigMap runs only on **first initialization of an empty data directory**.

That means:

- if the PVC already contains data, the init scripts do **not** rerun
- changing the Secret later does **not** automatically change the live PostgreSQL role password
- if you want a true clean bootstrap, you must delete the PVC too

### 4. SecurityContext note
The working StatefulSet intentionally keeps only pod-level seccomp:

- `seccompProfile: RuntimeDefault`

Do **not** re-add:

- container capability drop rules that prevent PostgreSQL entrypoint ownership fixes
- pod `fsGroup` settings used in the earlier failed version

The current StatefulSet is the corrected working version.

---

# Files in this directory

## `1-namespace.yaml`
Creates the namespace:

- `databases-prod`

## `2-secret.yaml`
Stores:

- PostgreSQL superuser password
- application database name
- application database user
- application database password

## `3-init-configmap.yaml`
Bootstrap script that runs on first initialization to:

- create the application role
- set its password
- create the application database
- grant ownership and schema access

## `4-services.yaml`
Creates:

- `postgresql-hl` = headless service for StatefulSet identity
- `postgresql` = ClusterIP service for internal application access

## `5-networkpolicy.yaml`
Creates network policies so PostgreSQL only accepts connections from:

- pods in `databases-prod`
- namespaces labeled `kakde.eu/postgresql-access=true`

## `6-statefulset.yaml`
Creates the PostgreSQL StatefulSet with:

- image `postgres:17.9`
- one replica
- 80Gi persistent volume claim
- node selector for the labeled database node
- readiness, liveness, and startup probes

---

# Prerequisites

## 1. Label the target node
Recommended:

```bash
kubectl label node wk-1 kakde.eu/postgresql=true --overwrite
kubectl get nodes --show-labels | grep kakde.eu/postgresql=true
```

## 2. Label application namespaces that may access PostgreSQL
For production apps:

```bash
kubectl label namespace apps-prod kakde.eu/postgresql-access=true --overwrite
kubectl get ns --show-labels | grep apps-prod
```

If later you also want dev apps to access this PostgreSQL instance, label `apps-dev` intentionally.

## 3. Edit secret values before apply
Update the placeholder passwords in:

- `2-secret.yaml`

You should use long random passwords.

---

# Apply order

Run from this directory:

```bash
cd ~/deployment/postgresql

kubectl apply -f 1-namespace.yaml
kubectl apply -f 2-secret.yaml
kubectl apply -f 3-init-configmap.yaml
kubectl apply -f 4-services.yaml
kubectl apply -f 5-networkpolicy.yaml
kubectl apply -f 6-statefulset.yaml
```

---

# Verification

## 1. Check resources

```bash
kubectl -n databases-prod get all,pvc,configmap,secret,networkpolicy
```

Expected:

- `statefulset.apps/postgresql`
- pod `postgresql-0`
- `service/postgresql`
- `service/postgresql-hl`
- `pvc/data-postgresql-0`
- `secret/postgresql-auth`
- `configmap/postgresql-init`
- network policies present

## 2. Check rollout

```bash
kubectl -n databases-prod rollout status statefulset/postgresql --timeout=300s
kubectl -n databases-prod get pod postgresql-0 -o wide
kubectl -n databases-prod get pvc
```

Expected:

- StatefulSet rollout succeeds
- `postgresql-0` is `1/1 Running`
- PVC is `Bound`
- pod is scheduled on `wk-1` (or the node you labeled)

## 3. Check logs

```bash
kubectl -n databases-prod logs postgresql-0 | tail -n 80
```

Expected:

- no permission errors
- normal PostgreSQL startup messages
- database ready to accept connections

## 4. Check service endpoints

```bash
kubectl -n databases-prod get svc
kubectl -n databases-prod get endpointslice
```

Expected:

- `postgresql` exists on port `5432`
- EndpointSlice points to the PostgreSQL pod IP

---

# Connection details for internal applications

Applications inside the cluster should use:

- **Host:** `postgresql.databases-prod.svc.cluster.local`
- **Port:** `5432`
- **Database:** `appdb`
- **User:** `appuser`
- **Password:** from `2-secret.yaml`

Do not expose this service externally.

---

# Test commands

## 1. Login test as application user

```bash
kubectl -n databases-prod exec -it postgresql-0 -- sh -lc \
'export PGPASSWORD="$APP_DB_PASSWORD"; \
psql -v ON_ERROR_STOP=1 -h postgresql -U "$APP_DB_USER" -d "$APP_DB_NAME" \
-c "select current_database(), current_user;"'
```

Expected:

- `current_database = appdb`
- `current_user = appuser`

## 2. Write/read test

```bash
kubectl -n databases-prod exec -it postgresql-0 -- sh -lc \
'export PGPASSWORD="$APP_DB_PASSWORD"; \
psql -v ON_ERROR_STOP=1 -h postgresql -U "$APP_DB_USER" -d "$APP_DB_NAME" <<'"'"'SQL'"'"'
CREATE TABLE IF NOT EXISTS healthcheck (
  id serial PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO healthcheck DEFAULT VALUES;
SELECT count(*) AS rows FROM healthcheck;
SQL'
```

Expected:

- `CREATE TABLE`
- `INSERT 0 1`
- row count at least `1`

---

# App namespace access model

The NetworkPolicy allows access only from namespaces labeled:

- `kakde.eu/postgresql-access=true`

Recommended:

- label `apps-prod` only if this DB is for production apps
- do not label other namespaces unless needed

Example:

```bash
kubectl label namespace apps-prod kakde.eu/postgresql-access=true --overwrite
```

---

# Password rotation note

Changing the Kubernetes Secret later does **not** automatically update the live PostgreSQL user password.

If you rotate the app password in the Secret, you must also update the PostgreSQL role password in the running database.

Example SQL:

```sql
ALTER ROLE appuser WITH LOGIN PASSWORD 'new-password';
```

Operational rule:

- Secret value = intended credential
- PostgreSQL internal role = actual credential in use

Both must match.

---

# Backup basics

Because this uses `local-path` storage, backups are important.

## Logical backup of the app database

```bash
kubectl -n databases-prod exec postgresql-0 -- sh -lc \
'export PGPASSWORD="$POSTGRES_PASSWORD"; pg_dump -U postgres -d "$APP_DB_NAME" -Fc' \
> appdb-$(date +%F).dump
```

## Full logical backup of all databases and globals

```bash
kubectl -n databases-prod exec postgresql-0 -- sh -lc \
'export PGPASSWORD="$POSTGRES_PASSWORD"; pg_dumpall -U postgres' \
> pg-all-$(date +%F).sql
```

Recommended practice:

- take regular backups
- store them off-cluster
- test restore periodically

---

# Restore basics

## Restore custom-format app backup

```bash
cat appdb-YYYY-MM-DD.dump | kubectl -n databases-prod exec -i postgresql-0 -- sh -lc \
'export PGPASSWORD="$POSTGRES_PASSWORD"; pg_restore -U postgres -d "$APP_DB_NAME" --clean --if-exists'
```

## Restore full SQL backup

```bash
cat pg-all-YYYY-MM-DD.sql | kubectl -n databases-prod exec -i postgresql-0 -- sh -lc \
'export PGPASSWORD="$POSTGRES_PASSWORD"; psql -U postgres -d postgres'
```

---

# Full cleanup / destroy

Use this only if you want to completely remove PostgreSQL and its data.

```bash
kubectl -n databases-prod delete statefulset postgresql --ignore-not-found
kubectl -n databases-prod delete service postgresql postgresql-hl --ignore-not-found
kubectl -n databases-prod delete configmap postgresql-init --ignore-not-found
kubectl -n databases-prod delete secret postgresql-auth --ignore-not-found
kubectl -n databases-prod delete networkpolicy postgresql-default-deny-ingress postgresql-allow-from-selected-namespaces --ignore-not-found
kubectl -n databases-prod delete pvc data-postgresql-0 --ignore-not-found
kubectl delete namespace databases-prod --ignore-not-found
```

Warning:

- deleting the PVC deletes the database data

---

# Fresh redeploy from zero

Use this when you want a fully clean redeploy.

```bash
cd ~/deployment/postgresql

kubectl label node wk-1 kakde.eu/postgresql=true --overwrite
kubectl label namespace apps-prod kakde.eu/postgresql-access=true --overwrite

kubectl apply -f 1-namespace.yaml
kubectl apply -f 2-secret.yaml
kubectl apply -f 3-init-configmap.yaml
kubectl apply -f 4-services.yaml
kubectl apply -f 5-networkpolicy.yaml
kubectl apply -f 6-statefulset.yaml
```

If you want a truly fresh bootstrap, ensure the old PVC is deleted before redeploying.

---

# Troubleshooting notes

## Pod starts but app login fails
Likely causes:

- app role was not created on first init
- app database was not created
- Secret password and live DB password are out of sync

Fix:

- connect as `postgres`
- explicitly create or alter the role and database
- verify app login again

## Init script changes do not take effect
Cause:

- existing PVC already contains initialized PostgreSQL data directory

Fix:

- delete StatefulSet
- delete PVC
- reapply manifests

## Permission errors during startup
If you see messages like:

- `Operation not permitted` on `chown`

Cause:

- a too-restrictive container securityContext was applied

Fix:

- keep the current corrected StatefulSet
- do not re-add dropped capabilities / old fsGroup settings

---

# Recommended next step

For application deployments in `apps-prod`, create a separate app-facing Secret there with:

- `DB_HOST`
- `DB_PORT`
- `DB_NAME`
- `DB_USER`
- `DB_PASSWORD`

Point those apps to:

- `postgresql.databases-prod.svc.cluster.local:5432`

