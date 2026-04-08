# Sealed Secrets

This cluster uses Bitnami Sealed Secrets to keep encrypted Kubernetes secrets in Git.

## Installed version

- Controller manifest: v0.33.1
- Namespace: `kube-system`
- Controller name: `sealed-secrets-controller`

## Install / upgrade

```bash
ssh root@192.168.15.2 kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.33.1/controller.yaml
```

## Create a sealed secret

1. Fetch the controller certificate:

```bash
ssh root@192.168.15.2 kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d > /tmp/sealed-secrets-cert.pem
```

2. Generate a Secret manifest and seal it with `kubeseal`:

```bash
kubectl create secret generic my-secret \
  --namespace my-namespace \
  --dry-run=client \
  --from-literal=my-key=my-value \
  -o yaml | \
  kubeseal \
    --cert /tmp/sealed-secrets-cert.pem \
    --format yaml > my-sealed-secret.yaml
```
