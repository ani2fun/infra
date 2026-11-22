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
ssh vm-1 'systemctl is-active homelab-fw-edge.service edge-guardrail.service nftables.service'
# expected: active (or exited) for each
ssh vm-1 'nft list tables | grep -c -E "inet (edgeguard|edge_guardrail)"'
# expected: 2 -- nftables.service active without `inet edgeguard` means the
# allowlist did not load. See gate L5-D.
```

**L0-D** OOM self-heal is actually in effect (not just configured).

Run this **after every node reboot** and after any k3s restart or upgrade.
Checking the file is not enough: `systemd-sysctl` applies
`20-oom-resilience.conf` correctly at boot, then the kubelet starts and resets
`vm.panic_on_oom` to 0 **silently**, because `--protect-kernel-defaults` is not
set. `oom-resilience-reassert.timer` is what puts the value back, within 5
minutes of each kubelet start. From 2026-06-13 to 2026-11-19 nobody checked the
live value, and the self-heal documented in `NODE-HARDENING.md` was off on all
four nodes the whole time.

```bash
for h in ms-1 wk-1 wk-2 vm-1; do
  echo "$h: live=$(ssh $h cat /proc/sys/vm/panic_on_oom)" \
       "panic=$(ssh $h cat /proc/sys/kernel/panic)s" \
       "timer=$(ssh $h systemctl is-active oom-resilience-reassert.timer)" \
       "unit=$(ssh $h systemctl show -p Result --value oom-resilience-reassert.service)"
done
# expected on every node: live=1  panic=10s  timer=active  unit=success
```

`live=0` with `timer=active` right after a reboot is **not yet a failure** --
the timer's first run is at `OnBootSec=2min`. Re-run the check after that.
`live=0` more than 5 minutes after boot **is** a failure.

If a node reports `live=0` persistently, read the unit's own verdict rather
than guessing:

```bash
ssh wk-1 'systemctl list-timers oom-resilience-reassert.timer --all; \
          journalctl -u oom-resilience-reassert.service -n 20 --no-pager'
# the service fails loudly (non-zero ExecStartPost) if the value did not stick
```

**L0-E** Nothing claims `--protect-kernel-defaults`.

The repo deliberately does **not** set it (see `NODE-HARDENING.md` for why: on a
single-control-plane cluster it converts a sysctl mismatch into a kubelet that
refuses to start). This gate exists so the choice stays a choice.

```bash
for h in ms-1 wk-1 wk-2 vm-1; do
  echo "$h: $(ssh $h 'grep -c protect-kernel-defaults /etc/systemd/system/k3s*.service /etc/rancher/k3s/config.yaml 2>/dev/null | paste -sd, -')"
done
# expected: 0 matches everywhere (missing config.yaml is normal -- all K3s flags
# live in INSTALL_K3S_EXEC in deploy/bootstrap/k3s/install-*.sh)
```

## L1 -- Router and DNS

**L1-A** Router port-forwards reachable from the edge node.

The probe runs *on vm-1*, which cannot look up the home WAN address itself,
so pass it in. Run the first line from the home LAN:

```bash
HOME_WAN_IP=$(curl -4 -fsS https://ifconfig.me)   # -4: plain curl may return IPv6
ssh vm-1 "for p in 51820 51821 51822; do timeout 2 nc -uvz $HOME_WAN_IP \$p 2>&1 | head -1; done"
# expected: each port reports "open" or "succeeded" (UDP probes may say
# "open|filtered"; the real test is layer 2)
```

Away from home, take the same address from vm-1's own allowlist instead:

```bash
HOME_WAN_IP=$(ssh vm-1 'awk -F= "/^ADMIN_SSH_ALLOW_IP/{print \$2}" /etc/edge-allowlist.env' | cut -d/ -f1)
```

**L1-B** Cloudflare A records resolve to the edge IP.

```bash
for h in kakde.eu argocd.kakde.eu keycloak.kakde.eu grafana.kakde.eu synapse.kakde.eu bytebase.kakde.eu; do
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
# expected: 4 rows, all STATUS=Ready, version v1.37.2+k3s1
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
ssh ms-1 'kubectl -n apps-prod get secret cortex-db -o jsonpath="{.data.postgres-password}" | head -c 6'
# expected: 6 characters of base64 (any value); confirms the controller
# successfully decrypted the committed deploy/apps/cortex/overlays/prod/sealedsecret.yaml
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

**L5-D** Edge SSH allowlist is active.

`edge_guardrail` (L5-B) accepts `tcp dport 22` on `eth0` from **anywhere**.
Only the `inet edgeguard` table at priority -200 restricts the source, so
L5-B passing does not mean SSH is locked down. Check the allowlist itself:

```bash
ssh vm-1 'nft list table inet edgeguard | grep "dport 22"'
# expected: ip saddr <operator-home-IP>/32 tcp dport 22 accept
# FAIL if: no output, or the rule has no `ip saddr` match
```

```bash
ssh vm-1 'systemctl is-active nftables.service; nft list tables | grep -c edgeguard'
# expected: active (or exited), and 2 (inet edgeguard + inet edge_guardrail)
```

Prove it from outside the allowlist -- from a phone hotspot or any host
that is not the operator's home IP:

```bash
timeout 5 nc -vz <edge-public-IP> 22
# expected: timeout / no route. A refused or open connection is a FAIL.
```

If this gate fails, re-run `prepare-host.sh` on vm-1 after confirming
`ADMIN_SSH_ALLOW_IP` in `/etc/edge-allowlist.env`. Do **not** reach for
`systemctl restart nftables.service` -- its `ExecStop` is
`nft flush ruleset` and takes Calico's tables with it.

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

**L7-B** All Applications Synced + Healthy.

```bash
ssh ms-1 'kubectl -n argocd get application -o wide'
# expected: 5 rows (bytebase, codefolio, monitoring, synapse, synapse-go-judge)
# all Synced + Healthy -- EXCEPT monitoring may be Progressing/Degraded until
# L11 seals its Grafana secrets (its metrics components come up Healthy on their own)
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
# expected: clients count >0, including cortex-web (if that's the
# Keycloak client name)
```

## L10 -- Apps and public reachability

**L10-A** Every public host responds.

```bash
for h in kakde.eu argocd.kakde.eu keycloak.kakde.eu \
         grafana.kakde.eu synapse.kakde.eu bytebase.kakde.eu; do
  printf "%-32s " "$h"
  curl -sI "https://$h/" -o /dev/null -w "%{http_code}\n" || echo "FAIL"
done
# expected: every line ends in 200, 302, 308, or 401 (auth-protected) -- never 5xx, never timeout
```

**L10-B** The Keycloak-gated app redirects to login rather than serving content.

```bash
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://bytebase.kakde.eu/
# expected: 302, redirecting to keycloak.kakde.eu/realms/bytebase/protocol/openid-connect/auth
# a 200 here means the oauth2-proxy gate has been bypassed -- treat as an incident
```

## L11 -- Monitoring

**L11-A** The monitoring Application is Synced + Healthy.

```bash
ssh ms-1 'kubectl -n argocd get application monitoring -o wide'
# expected: Synced + Healthy
```

**L11-B** vmsingle runs on wk-1 with a bound PVC.

```bash
ssh ms-1 'kubectl -n monitoring get pod -l app.kubernetes.io/name=vmsingle -o wide'
# expected: 1 pod Running on wk-1
ssh ms-1 'kubectl -n monitoring get pvc vmsingle-data'
# expected: STATUS=Bound
```

**L11-C** node-exporter covers all four nodes; vmagent targets are up.

```bash
ssh ms-1 'kubectl -n monitoring get ds node-exporter'
# expected: DESIRED=4 READY=4 (one per node, incl. ms-1 and vm-1)
ssh ms-1 'kubectl -n monitoring port-forward deploy/vmagent 8429:8429 >/dev/null 2>&1 &
  sleep 2; curl -s http://localhost:8429/api/v1/targets | grep -o "\"health\":\"[a-z]*\"" | sort | uniq -c; kill %1'
# expected: targets reporting "up" (investigate any "down")
```

**L11-D** vmsingle is receiving samples (remote_write path works).

```bash
ssh ms-1 'kubectl -n monitoring port-forward svc/vmsingle 8428:8428 >/dev/null 2>&1 &
  sleep 2; curl -s "http://localhost:8428/api/v1/query?query=count(up)"; echo; kill %1'
# expected: a data result with value > 0
```

**L11-E** Grafana answers publicly and enforces the GitHub OAuth lock.

```bash
curl -sI https://grafana.kakde.eu/ -o /dev/null -w "%{http_code}\n"
# expected: 302 (redirect to GitHub login) or 200
# manual: signing in with a GitHub account other than ani2fun must be REJECTED
```

## End-to-end gate

If every gate above is green, the cluster is back. Capture a fresh snapshot:

```bash
scripts/dr/snapshot-live-state.sh > deploy/dr/SNAPSHOT-$(date -u +%Y-%m-%d).md
```

Compare against `deploy/dr/SNAPSHOT.md` for any unexpected drift before
declaring done.
