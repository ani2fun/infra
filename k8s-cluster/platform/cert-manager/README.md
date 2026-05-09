# cert-manager and ClusterIssuers

This folder captures the documented TLS pattern:

- cert-manager installed by Helm into `cert-manager`
- Cloudflare DNS-01 token stored as `secret/cloudflare-api-token`
- production issuer `letsencrypt-prod-dns01`
- staging issuer `letsencrypt-staging-dns01`

## Pinned version

The Helm chart is pinned in `install-cert-manager.sh` to `v1.19.1`. The
version source of truth is [`../../dr/SNAPSHOT.md`](../../dr/SNAPSHOT.md).
Override at install time with `CERT_MANAGER_VERSION=...`.

## Cloudflare API token

The token lives in `cert-manager/cloudflare-api-token` (key: `api-token`)
and is **not** in Git. On rebuild you regenerate it in the Cloudflare
dashboard (Zone-DNS edit on `kakde.eu`) and apply with:

```bash
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token='<<NEW_TOKEN_VALUE>>'
```

See [`../../dr/secret-recovery.md`](../../dr/secret-recovery.md) for the
full secret recovery decision tree.
