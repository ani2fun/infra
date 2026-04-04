# cert-manager and ClusterIssuers

This folder captures the documented TLS pattern:

- cert-manager installed by Helm into `cert-manager`
- Cloudflare DNS-01 token stored as `secret/cloudflare-api-token`
- production issuer `letsencrypt-prod-dns01`
- staging issuer `letsencrypt-staging-dns01`

The install command in docs did not pin a chart version, so the live chart version still needs to be confirmed from the cluster export.

