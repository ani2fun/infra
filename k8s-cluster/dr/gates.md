# Verification gates

Mechanical "is this layer up?" checks. The runbook references each entry
by ID. If any expected output diverges, **fix it before moving to the
next layer**.

## L0 -- Host OS

**L0-A** Hostname matches inventory expectation.

```bash
for h in ms-1 wk-1 wk-2 vm-1; do echo "$h: $(ssh $h hostname)"; done
# expected: ms-1, wk-1, wk-2, ctb-edge-1
```

**L0-B** Swap is off, sysctl values are correct, modules are loaded.

```bash
ssh ms-1 './host-prep/prepare-host.sh'   # idempotent; the trailing block is the gate
```

The verification block at the end of `prepare-host.sh` should print:

- `[swap-state] OFF (good)`
- `[sysctl] net.ipv4.ip_forward = 1`
- `[sysctl] net.bridge.bridge-nf-call-iptables = 1`
- `[sysctl] net.ipv4.conf.all.rp_filter = 2`
- `[sysctl] net.ipv4.conf.wg0.rp_filter = 0` (after wg0 exists; on first
  run this is `?` -- normal)
- `[module] br_netfilter loaded`, `vxlan loaded`, `overlay loaded` (edge
  may not have `overlay`)

**L0-C** Custom firewall systemd units enabled where expected.

```bash
ssh ms-1 'systemctl is-active homelab-fw-ms1.service k3s-api-lockdown.service k3s-api-lockdown-allow-cluster.service'
ssh vm-1 'systemctl is-active homelab-fw-edge.service edge-guardrail.service'
# expected: active for each
```

## L1 -- Router and DNS

**L1-A** Router port-forwards reachable from the edge node.

```bash
ssh vm-1 'for p in 51820 51821 51822; do timeout 2 nc -uvz 82.123.119.181 $p 2>&1 | head -1; done'
# expected: each port reports "open" or "succeeded" (UDP probes may say
# "open|filtered"; the real test is layer 2)
```

**L1-B** Cloudflare A records resolve to the edge IP.

```bash
for h in kakde.eu dev.codefolio.kakde.eu argocd.kakde.eu keycloak.kakde.eu whoami.kakde.eu dsa-tracker.kakde.eu; do
  echo "$h -> $(dig +short $h @1.1.1.1)"
done
# expected: every record returns 84.247.143.66
```

## L2 -- WireGuard mesh

**L2-A** Each node sees three peers.

```bash
for h in ms-1 wk-1 wk-2 vm-1; do
  echo "==> $h"; ssh $h 'wg show wg0 | grep -c "^peer"'
done
# expected: 3 on every node (potentially 4 if you also have an admin peer)
```

**L2-B** Full-mesh ping over wg0.

```bash
for src in ms-1 wk-1 wk-2 vm-1; do
  for dst in 172.27.15.12 172.27.15.11 172.27.15.13 172.27.15.31; do
    ssh $src "ping -c1 -W2 $dst >/dev/null && echo $src->$dst:OK || echo $src->$dst:FAIL"
  done
done
# expected: every pair OK
```

## L3 -- K3s and Calico

**L3-A** All four nodes Ready.

```bash
ssh ms-1 'kubectl get nodes -o wide'
# expected: 4 rows, all STATUS=Ready, version v1.35.1+k3s1
```

**L3-B** Calico pods Running.

```bash
ssh ms-1 'kubectl -n calico-system get pods'
# expected: calico-node DaemonSet has one Running pod per node;
# calico-apiserver, calico-typha, calico-kube-controllers all Running
```

**L3-C** CoreDNS resolves cluster service.

```bash
ssh ms-1 'kubectl run -n default --rm -it --image=busybox:1.36 --restart=Never tmp-dns -- nslookup kubernetes.default.svc.cluster.local'
# expected: returns 10.43.0.1
```

## L4 -- Sealed-Secrets controller

**L4-A** Controller running, active key matches snapshot fingerprint.

```bash
ssh ms-1 'kubectl -n kube-system get deploy sealed-secrets-controller'
# expected: 1/1 ready

ssh ms-1 'kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o jsonpath="{.items[0].data.tls\.crt}"' \
  | base64 -d \
  | openssl x509 -noout -fingerprint -sha256
# expected: matches the fingerprint recorded in your password manager
# (compare against SNAPSHOT.md or the value printed by sealed-secrets-key-backup.sh)
```

**L4-B** A committed SealedSecret can decrypt.

```bash
ssh ms-1 'kubectl -n apps-prod get secret dsa-tracker-db -o jsonpath="{.data.postgres-password}" | head -c 6'
# expected: 6 characters of base64 (any value); confirms the controller
# successfully decrypted the committed deploy/dsa-tracker/overlays/prod/sealedsecret.yaml
```

## L5 -- Traefik

**L5-A** Traefik pod scheduled on the edge node only.

```bash
ssh ms-1 'kubectl -n traefik get pods -o wide'
# expected: 1 pod Running on ctb-edge-1
```

**L5-B** Edge guardrail rules present.

```bash
ssh vm-1 'nft list table inet edge_guardrail | head -20'
# expected: chain "input" with policy drop, accept rules for lo, established,
# wg0/cali*, ICMP, SSH, 80/443 on eth0
```

**L5-C** Public listener answers.

```bash
curl -sI http://84.247.143.66 | head -1
# expected: HTTP/1.1 404 Not Found  (Traefik default 404 for unmatched route)
# expected: HTTP/1.1 308 Permanent Redirect  (if HTTP->HTTPS redirect is on)
```

## L6 -- cert-manager

**L6-A** ClusterIssuers Ready.

```bash
ssh ms-1 'kubectl get clusterissuer -o jsonpath="{range .items[*]}{.metadata.name}={.status.conditions[?(@.type==\"Ready\")].status}{\"\n\"}{end}"'
# expected: letsencrypt-prod-dns01=True
#           letsencrypt-staging-dns01=True
```

**L6-B** Cloudflare token Secret exists.

```bash
ssh ms-1 'kubectl -n cert-manager get secret cloudflare-api-token -o jsonpath="{.data.api-token}" | head -c 8'
# expected: 8 characters of base64 (any value)
```

## L7 -- Argo CD

**L7-A** Argo CD pods all Running.

```bash
ssh ms-1 'kubectl -n argocd get pods'
# expected: server, application-controller (StatefulSet), repo-server,
# applicationset-controller, dex-server, redis, notifications-controller
# all Running
```

**L7-B** All three Applications Synced + Healthy.

```bash
ssh ms-1 'kubectl -n argocd get application -o wide'
# expected: 3 rows (codefolio, dsa-tracker, piston)
# all Synced + Healthy
```

**L7-C** Argo CD UI reachable.

```bash
curl -sI https://argocd.kakde.eu/ | head -1
# expected: HTTP/2 200
```

## L8 -- PostgreSQL

**L8-A** StatefulSet pod running on wk-1.

```bash
ssh ms-1 'kubectl -n databases-prod get pods -o wide'
# expected: postgresql-0 Running on wk-1
```

**L8-B** pg_isready inside the pod.

```bash
ssh ms-1 'kubectl -n databases-prod exec postgresql-0 -- pg_isready -U postgres'
# expected: postgresql-0:5432 - accepting connections
```

**L8-C** All expected databases exist.

```bash
ssh ms-1 'kubectl -n databases-prod exec postgresql-0 -- psql -U postgres -At -c "SELECT datname FROM pg_database WHERE datname NOT IN (\"template0\",\"template1\",\"postgres\") ORDER BY datname"'
# expected: at least `keycloak`, `dsa_tracker`, `appdb` (depending on what
# you actually use; cross-reference against the inventory file in your
# postgres backup)
```

## L9 -- Keycloak

**L9-A** Pod ready.

```bash
ssh ms-1 'kubectl -n identity get pods'
# expected: keycloak-* Running with READY 1/1
```

**L9-B** OIDC discovery endpoint serves.

```bash
curl -sI https://keycloak.kakde.eu/realms/kakde/.well-known/openid-configuration | head -1
# expected: HTTP/2 200
```

**L9-C** Realm has its expected clients.

```bash
ssh ms-1 'scripts/dr/backup-keycloak-realm.sh /tmp'
# expected: clients count >0, including dsa-tracker-web (if that's the
# Keycloak client name)
```

## L10 -- Apps and public reachability

**L10-A** Every public host responds.

```bash
for h in kakde.eu dev.codefolio.kakde.eu \
         argocd.kakde.eu keycloak.kakde.eu whoami.kakde.eu \
         dsa-tracker.kakde.eu; do
  printf "%-32s " "$h"
  curl -sI "https://$h/" -o /dev/null -w "%{http_code}\n" || echo "FAIL"
done
# expected: every line ends in 200, 302, 308, or 401 (auth-protected) -- never 5xx, never timeout
```

**L10-B** Optional: whoami-auth (only if you've activated the oauth2-proxy template).

```bash
curl -sI https://whoami-auth.kakde.eu | head -1
# expected: HTTP/2 302 (redirect to Keycloak login)
```

## End-to-end gate

If every gate above is green, the cluster is back. Capture a fresh snapshot:

```bash
scripts/dr/snapshot-live-state.sh > k8s-cluster/dr/SNAPSHOT-$(date -u +%Y-%m-%d).md
```

Compare against `dr/SNAPSHOT.md` for any unexpected drift before declaring
done.
