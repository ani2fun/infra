# Monitoring (metrics)

Phase-1 observability for the homelab: **metrics + dashboards only**. The stack
is [VictoriaMetrics](https://victoriametrics.com) (single-node TSDB) + `vmagent`
(scraper) + `node-exporter` + `kube-state-metrics` + Grafana, all in the
`monitoring` namespace and **Argo-synced** from `overlays/prod`.

Why VictoriaMetrics over Prometheus: ~5–10× lower RAM/disk for the same data
(this cluster is RAM-tight — wk-1 has an OOM history), while staying
Prometheus-query-API compatible so Grafana + PromQL + community dashboards all
work unchanged. Plain Kustomize manifests, no Helm — consistent with the rest of
the repo. Logs (VictoriaLogs) and traces (Tempo) are deferred to later phases;
the `annotated-pods` scrape job is already in place so app `/metrics` endpoints
(cortex, …) can be scraped later with no config change.

## Before you deploy — check headroom

`vmsingle` is pinned to **wk-1** (its `local-path` PVC is node-local, so the pin
makes the data location deterministic — same rationale as `go-judge`). Confirm
wk-1 has room first; if not, change the one `nodeSelector` line in
`base/vmsingle-deployment.yaml` to `wk-2`.

```bash
ssh ms-1 'kubectl top nodes'
ssh wk-1 'free -h && df -h /var/lib/rancher/k3s/storage'
```

## Layout

- `base/vmsingle-{deployment,pvc,service}.yaml` — metrics store, 30d retention, 20Gi local-path PVC on wk-1
- `base/vmagent-{rbac,scrape-configmap,deployment}.yaml` — scraper (5 jobs: kubelet, cAdvisor, node-exporter, kube-state-metrics, annotated-pods)
- `base/node-exporter-{daemonset,service}.yaml` — host metrics on **all 4 nodes** (tolerates control-plane + edge taints)
- `base/kube-state-metrics-{rbac,deployment,service}.yaml` — Kubernetes object-state metrics
- `base/grafana-{datasource,dashboards-provider,dashboards}-configmap.yaml` — provisioned datasource (vmsingle) + a starter "Homelab Overview" dashboard
- `base/grafana-{deployment,service}.yaml` — Grafana with GitHub OAuth
- `overlays/prod/ingress.yaml` — `grafana.kakde.eu` (Traefik + cert-manager, same pattern as cortex/keycloak)
- `overlays/prod/grafana-admin-sealedsecret.yaml` — `grafana-admin` (break-glass local login)
- `overlays/prod/grafana-github-oauth-sealedsecret.yaml` — `grafana-github-oauth` (client id + secret)

## Access & auth

Grafana is exposed publicly at `grafana.kakde.eu` (edge Traefik, like
`argocd.kakde.eu` / `keycloak.kakde.eu`) but **login is locked to GitHub user
`ani2fun`** via Grafana's native GitHub OAuth. The lock is the
`role_attribute_path` JMESPath (`login=='ani2fun' && 'GrafanaAdmin' || ''`) plus
`role_attribute_strict=true`: every other GitHub account is denied. Add a user
later by extending that path, e.g.
`contains(['ani2fun','newperson'], login) && 'Editor' || ''`.

**Break-glass:** the local admin (sealed `grafana-admin`) login still works via
`kubectl -n monitoring port-forward svc/grafana 3000:80` → <http://localhost:3000>.

## Secrets referenced

- `grafana-github-oauth` — GitHub OAuth App client id + secret (keys: `client-id`,
  `client-secret`). Restored automatically by sealed-secrets if the controller
  key is present, otherwise recreate the OAuth App at github.com and reseal.
- `grafana-admin` — break-glass local admin (keys: `admin-user`, `admin-password`).

Both ship as **placeholder** SealedSecrets — seal real values before the first
Argo sync or Grafana won't start. See [`../../dr/secret-recovery.md`](../../dr/secret-recovery.md).

## Operator setup (one-time)

1. **GitHub OAuth App** — github.com → Settings → Developer settings → OAuth
   Apps → New. Homepage `https://grafana.kakde.eu`; callback
   `https://grafana.kakde.eu/login/github`. Copy Client ID + generate a secret.
2. **DNS** — point `grafana.kakde.eu` at the edge IP `84.247.143.66` in Cloudflare.
3. **Seal the two secrets** (against the active controller cert):

   ```bash
   ssh ms-1 "kubectl get secret -n kube-system \
     -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
     -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d" > /tmp/ss-cert.pem

   kubectl create secret generic grafana-github-oauth --namespace monitoring \
     --from-literal=client-id='<id>' --from-literal=client-secret='<secret>' \
     --dry-run=client -o yaml | kubeseal --cert /tmp/ss-cert.pem --format yaml \
     > overlays/prod/grafana-github-oauth-sealedsecret.yaml

   kubectl create secret generic grafana-admin --namespace monitoring \
     --from-literal=admin-user='admin' --from-literal=admin-password='<strong>' \
     --dry-run=client -o yaml | kubeseal --cert /tmp/ss-cert.pem --format yaml \
     > overlays/prod/grafana-admin-sealedsecret.yaml
   ```

4. **Sync** — `kubectl apply -f ../../platform/argocd/applications/monitoring.yaml`.

## Community dashboards

The starter "Homelab Overview" dashboard ships in-repo. Import the richer
community ones via the UI (Dashboards → New → Import → enter ID → pick the
VictoriaMetrics datasource): **1860** (Node Exporter Full), **15757**
(Kubernetes views), **10229** (VictoriaMetrics single-node). GitOps-manage any
of them later by adding their JSON to `base/grafana-dashboards-configmap.yaml`.

## Live cluster verification

```bash
kubectl -n argocd get application monitoring -o wide              # Synced + Healthy
kubectl -n monitoring get pods -o wide                            # node-exporter on all 4 nodes
kubectl -n monitoring get pod -l app.kubernetes.io/name=vmsingle -o wide   # NODE == wk-1
kubectl -n monitoring port-forward deploy/vmagent 8429:8429 &
curl -s 'http://localhost:8429/api/v1/targets' | grep -o '"health":"[a-z]*"' | sort | uniq -c
curl -sI https://grafana.kakde.eu/ -o /dev/null -w '%{http_code}\n'   # 302 -> GitHub login
```

## See also

- [`../../dr/RUNBOOK.md`](../../dr/RUNBOOK.md) — operator runbook (Layer 11)
- [`../../dr/gates.md`](../../dr/gates.md) — verification gates (L11)
- [`../../dr/secret-recovery.md`](../../dr/secret-recovery.md) — secret-by-secret recovery
- [`../../platform/sealed-secrets/README.md`](../../platform/sealed-secrets/README.md) — kubeseal workflow
