# Sealed-Secrets master key backup and restore

The Sealed-Secrets controller in `kube-system` owns a private key pair that
encrypts and decrypts every `SealedSecret` in this repo. **If that key is
lost, every committed `SealedSecret` becomes garbage** -- the controller on
a freshly-installed cluster will issue a new key, and the encrypted blobs
in Git no longer match.

## Why this matters

SealedSecrets are committed to Git and depend on the live controller key.
Currently:

- `deploy/apps/dsa-tracker/overlays/prod/sealedsecret.yaml`
- `deploy/apps/dsa-tracker/overlays/dev/sealedsecret.yaml`
- `deploy/apps/codefolio/overlays/prod/sealedsecret.yaml`

If the master key is unrecoverable, every plaintext value behind those
files must be regenerated at source (database password rotation) and
resealed against the new controller key.

## What to back up

A single Kubernetes Secret in `kube-system` labeled
`sealedsecrets.bitnami.com/sealed-secrets-key=active`. The current cluster
has two active keys (rotation history); the restore brings back both.

Live verification:

```bash
ssh ms-1 "kubectl get secrets -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o name"
```

## Backup procedure

```bash
scripts/dr/sealed-secrets-key-backup.sh /path/to/secure/dir/
```

The script:

1. Connects to `ms-1` and exports the labeled secret(s) as a YAML file.
2. Sets file mode `0600`.
3. Prints the SHA-256 of the resulting file.

**Where to store the resulting file:**

- A password manager attachment (1Password, Bitwarden, etc.).
- An encrypted USB stick kept off-premises.
- **Never** in Git, dropbox, email, or any unencrypted cloud storage.

Record the SHA-256 of the backup file in your password manager so on
restore day you can verify the file you reach for is the file you backed up.

## Restore procedure

On a freshly-installed cluster, after the Sealed-Secrets controller is
running but before any `SealedSecret` is applied:

```bash
scripts/dr/sealed-secrets-key-restore.sh /path/to/backup-file.yaml
```

The script:

1. Validates the YAML.
2. Scales the controller to 0.
3. Applies the backup secret.
4. Scales the controller back to 1.
5. Waits for the rollout to finish.
6. Prints the active cert digest so you can compare against
   `deploy/dr/SNAPSHOT.md`.

If the printed digest matches the snapshot, every committed `SealedSecret`
will decrypt cleanly when applied.

## Rotation

Best practice is to rotate annually or after any suspected compromise.
Rotation is destructive: every committed `SealedSecret` must be re-emitted
against the new key.

1. Take a backup with the script above (in case rotation goes wrong).
2. Delete the active `sealedsecrets.bitnami.com/sealed-secrets-key=active`
   secrets in `kube-system`.
3. Restart the controller. It will generate a fresh key and label it
   active.
4. Take a new backup of the new active key.
5. For every committed `SealedSecret` file in Git, regenerate it using
   `scripts/secrets/rotate-generic-secret.sh` or the relevant
   app-specific wrapper, and overwrite the file in place.
6. Commit and push. Argo CD will sync the re-sealed manifests.

## What if the key is irrecoverable

If you have neither the live cluster nor a backup of the master key:

- `cloudflare-api-token` -- regenerate at Cloudflare; apply directly with
  `kubectl create secret`.
- `dsa-tracker-db` -- choose a new password; update the postgres role and
  reseal with `scripts/secrets/rotate-generic-secret.sh`.
- `codefolio-db` -- same procedure as `dsa-tracker-db`.

See `secret-recovery.md` for the full decision tree.

## See also

- [`../platform/sealed-secrets/README.md`](../platform/sealed-secrets/README.md) -- the workflow doc
- [`secret-recovery.md`](secret-recovery.md) -- secret-by-secret recovery decisions
- `scripts/dr/sealed-secrets-key-backup.sh`
- `scripts/dr/sealed-secrets-key-restore.sh`
