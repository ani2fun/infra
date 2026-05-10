# Live capture

`collect-live-state.sh` is an audit/snapshot tool that SSHes into the
four cluster nodes (using `vm-1` as a jump host for the home nodes) and
dumps a comprehensive picture of the running state into
`output/<timestamp>/`.

Use it when you want to:

- compare the live cluster against what the repo says (drift detection)
- gather host-level facts after a rebuild to confirm the new node
  matches expectations
- bootstrap a new `deploy/dr/SNAPSHOT.md` after a major change

Prerequisites: `~/.ssh/config` aliases for `ms-1`, `wk-1`, `wk-2`, `vm-1`
reaching `root@`.

## What gets captured

**Per host** (one `host.txt` file each):
hostname, OS, kernel, timedatectl, swap, kernel modules,
k8s/networking sysctls, `apt-mark showmanual`, sshd effective config
(filtered to a handful of policy keys -- no host keys, no
`authorized_keys`), custom firewall systemd unit state, IP addresses,
routes, IP rules, `wg show`, `wg0.conf` (with **`PrivateKey =` lines
redacted by awk**), K3s resolver config, K3s + edge-guardrail systemd
units (via `systemctl cat`), nftables ruleset, iptables-save.

**Cluster-wide** (under `cluster/`):
nodes (wide + yaml), namespaces (labels + yaml), ingress classes,
storage classes, persistent volumes, all Argo CD `Application` objects,
all cert-manager objects (`clusterissuer`, `certificate`,
`certificaterequest`, `order`, `challenge`).

**Per namespace** (`argocd`, `apps-prod`, `apps-dev`, `databases-prod`,
`cert-manager`, `traefik`, plus best-effort Keycloak discovery):
`namespace.yaml` and `resources.yaml` (all + ingress + configmap + pvc +
networkpolicy + serviceaccount + role + rolebinding) plus
`secrets-metadata.txt`.

## Secret handling

What is **NOT** captured:

- **Secret values**: `kubectl get secret` is invoked with
  `-o custom-columns=NAME:.metadata.name,TYPE:.type` so only the name
  and type land in `secrets-metadata.txt`. The encoded `.data` field
  never leaves the cluster.
- **WireGuard private keys**: `/etc/wireguard/wg0.conf` is piped through
  awk that replaces every `PrivateKey =` line with
  `PrivateKey = <redacted>` before the content is written.
- **SSH host keys, authorized_keys, user keys**: `sshd -T` output is
  filtered to a small allowlist of policy directives.

What **IS** captured -- be aware:

- **ConfigMaps in full YAML.** Anything you put in a ConfigMap will be
  in the dump verbatim. The current ConfigMaps in this cluster are
  configuration-only (e.g., the postgres init script reads passwords
  from env vars sourced from the `postgresql-auth` Secret), but if you
  ever add a ConfigMap with embedded credentials or tokens, those will
  appear in the dump.
- **K3s systemd units** via `systemctl cat`. The K3s installer puts the
  cluster join token in a separate 0600 file
  (`/var/lib/rancher/k3s/server/node-token`), not the unit, so this is
  normally safe. But if your K3s install added `Environment=K3S_TOKEN=...`
  to the unit, that token would appear in the dump.
- **Firewall rules** (`nft list ruleset`, `iptables-save`). These reveal
  which IPs are allowlisted -- includes your home IP via
  `ADMIN_SSH_ALLOW_IP`.

The output directory tree is listed in `.gitignore` and **must not be
committed** to git. Treat the dump like any other operator artifact:
encrypted off-cluster storage if retained, deleted otherwise.

## Run it

```bash
deploy/live-capture/collect-live-state.sh
# writes deploy/live-capture/output/<timestamp>/

deploy/live-capture/collect-live-state.sh /tmp/state-2026-05-10
# or write to an explicit path outside the repo
```

## Related: DR snapshotting

For a structured, committed snapshot that pins versions, image digests,
Argo CD revisions, and host facts in a single markdown file, use
[`scripts/dr/snapshot-live-state.sh`](../../scripts/dr/snapshot-live-state.sh)
instead. That one is selective and produces output meant to live in git;
this collector is the broader raw dump that is **not** meant to be
committed. See [`../dr/SNAPSHOT.md`](../dr/SNAPSHOT.md) for the current
frozen reference.
