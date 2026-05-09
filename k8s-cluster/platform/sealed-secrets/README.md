# Sealed Secrets

This cluster uses Bitnami Sealed Secrets to keep secret values out of Git while still letting Argo CD deploy them declaratively.

The core idea is:

1. You create a normal Kubernetes `Secret` manifest locally.
2. You encrypt it into a `SealedSecret` with the cluster public certificate.
3. You commit only the encrypted `SealedSecret` to Git.
4. The Sealed Secrets controller in the cluster decrypts it and creates the real runtime `Secret`.

That gives you GitOps-friendly secret management without storing plain-text secrets in the repo.

## Installed version

- Controller manifest: `v0.33.1`
- Namespace: `kube-system`
- Controller name: `sealed-secrets-controller`

## Why we use this

Before Sealed Secrets, the secret value could end up in Git as plain text.

With Sealed Secrets:

- Git stores only encrypted data
- Argo CD can still deploy secrets automatically
- the real secret exists only inside the cluster
- you can safely keep app manifests and secret manifests in the same repo

## How it works in this cluster

The controller runs in `kube-system` and owns a private key pair.

- Public certificate: used locally with `kubeseal` to encrypt data
- Private key: stays in the cluster and is used by the controller to decrypt and create the real Kubernetes `Secret`

Important consequence:

- you can create new sealed secrets anywhere you have the public cert
- you cannot recover the original plain-text value from Git alone
- recovery of the plain-text value requires access to the live Kubernetes `Secret` in the cluster, or another external source where you originally stored it

## Install or upgrade the controller

```bash
ssh root@192.168.15.2 \
  kubectl apply -f \
  https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.33.1/controller.yaml
```

## Install the local tooling

On macOS:

```bash
brew install kubeseal
```

Verify:

```bash
kubeseal --version
```

## Fetch the public certificate

You need the controller public certificate on your machine before you can seal secrets.

```bash
ssh root@192.168.15.2 \
  "kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d" \
  > /tmp/sealed-secrets-cert.pem
```

You can reuse this file for future sealing commands until the controller key changes.

## Basic workflow

### 1. Create a normal Secret manifest locally

Example:

```bash
kubectl create secret generic my-secret \
  --namespace my-namespace \
  --from-literal=my-key=my-value \
  --dry-run=client \
  -o yaml
```

### 2. Seal it

```bash
kubectl create secret generic my-secret \
  --namespace my-namespace \
  --from-literal=my-key=my-value \
  --dry-run=client \
  -o yaml | \
kubeseal \
  --cert /tmp/sealed-secrets-cert.pem \
  --format yaml \
  > my-sealed-secret.yaml
```

### 3. Commit the sealed file to Git

Only commit the generated `SealedSecret` YAML. Do not commit the original plain `Secret`.

### 4. Reference the runtime secret from your workload

Your Deployment/StatefulSet still reads a normal Kubernetes secret name:

```yaml
env:
  - name: MY_SECRET_VALUE
    valueFrom:
      secretKeyRef:
        name: my-secret
        key: my-key
```

The controller creates `Secret/my-secret` from `SealedSecret/my-secret`.

## Real example from this repo

For `dsa-tracker`, the encrypted manifests live here:

- `deploy/dsa-tracker/overlays/prod/sealedsecret.yaml`

It produces this runtime secret in `apps-prod`:

- `dsa-tracker-db`

And the app references them from:

- `deploy/dsa-tracker/base/backend-deployment.yaml`

Examples:

- `dsa-tracker-db` stores the PostgreSQL password
- DSA Tracker images are published from public GHCR packages, so the app no longer needs a registry pull secret

## Creating a generic app secret in the future

Example for a database password:

```bash
kubectl create secret generic my-app-db \
  --namespace apps-prod \
  --from-literal=password='replace-me' \
  --dry-run=client \
  -o yaml | \
kubeseal \
  --cert /tmp/sealed-secrets-cert.pem \
  --format yaml \
  > deploy/my-app/overlays/prod/sealedsecret.yaml
```

Then add that file to the relevant `kustomization.yaml`.

## Creating a Docker registry pull secret

For Docker Hub or another registry, use `docker-registry` type instead of a generic secret:

```bash
kubectl create secret docker-registry my-regcred \
  --namespace apps-prod \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username='your-user' \
  --docker-password='your-token' \
  --dry-run=client \
  -o yaml | \
kubeseal \
  --cert /tmp/sealed-secrets-cert.pem \
  --format yaml \
  > deploy/my-app/overlays/prod/registry-sealedsecret.yaml
```

Then reference it from the pod spec:

```yaml
spec:
  imagePullSecrets:
    - name: my-regcred
```

## Updating an existing secret

Sealed Secrets are not edited by hand.

Instead:

1. regenerate the secret from the new plain-text value
2. reseal it with `kubeseal`
3. overwrite the existing sealed YAML file
4. commit and push
5. let Argo CD sync it

Example:

```bash
kubectl create secret generic dsa-tracker-db \
  --namespace apps-prod \
  --from-literal=postgres-password='new-password' \
  --dry-run=client \
  -o yaml | \
kubeseal \
  --cert /tmp/sealed-secrets-cert.pem \
  --format yaml \
  > deploy/dsa-tracker/overlays/prod/sealedsecret.yaml
```

Project wrappers in this repo automate the common cases:

```bash
scripts/secrets/rotate-keycloak-github-oauth.sh <client-id> <client-secret>
```

## Where the encrypted data lives

The encrypted data lives in Git, inside the `SealedSecret` manifest under:

```yaml
spec:
  encryptedData:
    some-key: Ag...
```

Example from `dsa-tracker`:

```yaml
spec:
  encryptedData:
    postgres-password: Ag...
```

That encrypted blob is safe to commit. It is not the original secret value.

## Where the plain-text value lives

The plain-text value does not live in Git.

It exists in these places only:

- wherever you originally sourced it from
- your local terminal command while you are generating the secret
- the live Kubernetes `Secret` created by the Sealed Secrets controller

## How to recover a secret later

This is the important mental model:

- `SealedSecret` is for deployment
- `Secret` is the runtime decrypted object
- Git stores only the encrypted form

If you want the original value later, you recover it from the live Kubernetes `Secret`, not from the `SealedSecret`.

Example:

```bash
ssh root@192.168.15.2 \
  "kubectl get secret dsa-tracker-db -n apps-prod -o jsonpath='{.data.postgres-password}'" | \
base64 -d
```

So the recovery rule is:

- from Git: you recover only the encrypted blob
- from Kubernetes: you can recover the actual current secret value

## What happens if the cluster is lost

If the cluster is destroyed and you only have the Git repo:

- you still have the sealed secret manifests
- but you do not automatically have the plain-text secret values

That means you should still treat the original values as important credentials and store or regenerate them from a trusted source when needed.

Practical guidance:

- database passwords should be documented in your password manager or rotated from the database side
- Sealed Secrets protects Git, but it is not a replacement for credential lifecycle management

## Key rotation note

The controller manages its own sealing key pair.

If the controller key changes:

- old sealed secrets may need resealing for new workflows
- already decrypted runtime secrets in the cluster can still continue to exist

If you reinstall the controller from scratch without preserving its keys, previously committed sealed secrets may no longer decrypt on the new installation.

So for disaster recovery, remember:

- the Git repo contains encrypted secret manifests
- the cluster contains the private key that can decrypt them
- losing both the cluster keys and the original secret sources means you must recreate the secrets

## Master key backup and restore

The procedure for backing up and restoring the controller's master key is
documented in [`../../dr/sealed-secrets-key-backup.md`](../../dr/sealed-secrets-key-backup.md).
Helper scripts:

- `scripts/dr/sealed-secrets-key-backup.sh <output-dir>` -- export the live key to a YAML file (keep off-cluster)
- `scripts/dr/sealed-secrets-key-restore.sh <backup-yaml>` -- restore on a freshly-installed cluster

## Recommended team workflow

For future changes, use this pattern:

1. fetch `/tmp/sealed-secrets-cert.pem` if needed
2. generate the new secret locally with `kubectl create secret ... --dry-run=client -o yaml`
3. pipe it into `kubeseal`
4. save the result into the app overlay directory
5. reference the secret name from the Deployment
6. commit and push only the sealed YAML
7. let Argo CD sync it

## Helper scripts in this repo

For the common workflows, use the scripts under `scripts/secrets/`:

- `scripts/secrets/fetch-sealed-secrets-cert.sh` fetches the active Sealed Secrets public certificate
- `scripts/secrets/rotate-generic-secret.sh <namespace> <secret-name> <output-yaml> <key=value>...` reseals a generic secret
- `scripts/secrets/rotate-keycloak-github-oauth.sh <client-id> <client-secret>` updates the production Keycloak GitHub OAuth sealed secret
- `scripts/secrets/read-secret-value.sh <namespace> <secret-name> <key>` decodes a live runtime secret value
- `scripts/secrets/read-keycloak-admin-credentials.sh` prints the live Keycloak admin username and password
- `scripts/secrets/read-keycloak-db-password.sh` prints the live Keycloak database password
- `scripts/secrets/read-dsa-tracker-db-password.sh` prints the live DSA Tracker database password

These read scripts are intended for use on the Kubernetes controller or any machine with working `kubectl` access to the cluster.

## Quick checklist

- Never commit plain `Secret` manifests
- Commit `SealedSecret` manifests instead
- Reference the normal secret name from workloads
- Recover the actual value from the live Kubernetes `Secret` if needed
- Keep the original credential source somewhere trustworthy outside the cluster
