# Host preparation -- Layer 0

Everything that has to be true on a fresh Ubuntu 24.04.4 LTS install before
the rest of the recovery pack will work. WireGuard, K3s, and Calico all
assume the host is already prepared with the right packages, sysctl tuning,
kernel modules, network config, SSH hardening, and firewall services.

This directory captures that layer as files plus an idempotent
`prepare-host.sh` script that applies them.

## What this layer installs

| Concern | What | Notes |
|---|---|---|
| OS | Ubuntu 24.04.4 LTS | Server install on `vm-1`; desktop or server on home nodes |
| Kernel | HWE on home (`linux-generic-hwe-24.04`); `linux-virtual` on edge | Captured running kernels: home `6.17.x`, edge `6.8.x` |
| Packages | `packages-common.txt` (all) + `packages-home.txt` (ms-1/wk-1/wk-2) or `packages-edge.txt` (vm-1) | Pulled from live `apt-mark showmanual` |
| Swap | Disabled (`swapoff -a` + commented in `/etc/fstab`) | Required by K3s |
| Sysctl | `sysctl/99-k3s-calico.conf` + reuses `bootstrap/wireguard/99-wireguard.conf`; edge also keeps `sysctl/10-panic.conf` and `sysctl/99-cloudimg-ipv6.conf` | rp_filter is intentionally `2` globally and `0` on `wg0` -- see "rp_filter caveat" below |
| Kernel modules | `modules-load/k3s-calico.conf` (br_netfilter, vxlan) on every node; `modules-load/k8s.conf` (overlay, br_netfilter) on home only | Edge runs Traefik with hostNetwork, so the overlay storage driver isn't needed there |
| SSH | `ssh/99-root-login.conf` on home nodes (`PermitRootLogin prohibit-password`); `ssh/60-cloudimg-settings.conf` on edge | Edge keeps the cloud image SSH dropin; access is gated by `edge_guardrail` nftables allowlist |
| NTP | `systemd-timesyncd` on ms-1 and wk-1; `chronyd` on wk-2; `systemd-timesyncd` on vm-1 | wk-2 uses chrony historically; either daemon is fine |
| Timezone | `Europe/Paris` on home nodes; `Europe/Berlin` on vm-1 | Captured from live `timedatectl` |
| Hostname | `ms-1`, `wk-1`, `wk-2`, `ctb-edge-1` (vm-1) | The Kubernetes node name on vm-1 is `ctb-edge-1`, not `vm-1`; SSH alias is `vm-1` |
| Firewall (home) | `firewall/k3s-api-lockdown.service` + `homelab-fw-ms1.service` (ms-1 only currently) | Lock the K3s API to WireGuard peers; allow established, loopback, SSH, then drop |
| Firewall (edge) | `firewall/homelab-fw-edge.service` + the existing `platform/traefik/edge-guardrail.sh` | Two units run together; `homelab-fw-edge` blocks Kubernetes-internal ports on the public NIC, `edge-guardrail` is the strict eth0 allowlist |

## How to apply

After installing Ubuntu, copying the host-specific files (see `MANIFEST.md`),
and ensuring root SSH access works:

```bash
# As root on the target node
cd /root/host-prep            # wherever you copied this directory
./prepare-host.sh
```

The script is idempotent. Safe to re-run after a partial run. It detects the
node role from `/etc/hostname`. It will refuse to run if the hostname does
not match one of the four expected names.

After it finishes, the bottom of its output prints a verification block --
sysctl values, swap state, modules loaded, SSH effective config, NTP
status. All entries should be green; if anything is red, fix it before
moving on to WireGuard.

## What this layer does NOT install

- WireGuard config and private key -- see `../wireguard/`.
- K3s server/agent -- see `../k3s/`.
- Calico CNI -- see `../k3s/install-calico.sh`.
- Anything inside the cluster -- see `../../platform/`.

## Per-node caveats

### ms-1
- Currently has `ubuntu-desktop-minimal` installed for ad-hoc admin work.
  Not strictly required; the prep script will not install or remove the
  desktop. If you want it, install separately.
- Runs `homelab-fw-ms1.service`, `k3s-api-lockdown.service`, and
  `k3s-api-lockdown-allow-cluster.service`. The two `k3s-api-lockdown*`
  services are scoped to control-plane nodes only.

### wk-1
- Runs `ollama.service` for local model inference. Not Kubernetes-managed.
  Out of scope for this pack -- install separately if you want it back.
- PostgreSQL data lives on the same root filesystem (no separate disk).
  If you provision a separate data disk on rebuild, mount it at
  `/var/lib/rancher/k3s/storage` before installing K3s.

### wk-2
- **Wi-Fi.** wk-2 currently connects via the `wlo1` Wi-Fi interface to SSID
  `Macaw-Tucan`. The PSK lives in `/etc/netplan/50-cloud-init.yaml` in
  plaintext. The `netplan/wk-2.yaml.example` template ships a wired
  Ethernet block by default with the Wi-Fi block commented out and a
  `<<REPLACE_WITH_WIFI_PSK>>` placeholder. **Do not commit the live PSK
  to Git.** Pull it from the password manager when needed.
- Uses `chronyd` (not `systemd-timesyncd`). The prep script honours that.
- `/etc/hosts` has a long-standing typo: `192.162.15.4 wk2`. The prep
  script does not touch `/etc/hosts`; if you care, fix it manually --
  it does not affect cluster operation.

### vm-1 (ctb-edge-1)
- Cloud-init owns `/etc/hosts`. Do not edit it manually.
- The Kubernetes node name is `ctb-edge-1`, not `vm-1`. SSH alias `vm-1`
  is purely for operator convenience.
- `homelab-fw-edge.service` runs alongside the existing
  `platform/traefik/edge-guardrail.sh`. The two are deliberately separate:
  `edge-guardrail` is the hard nftables allowlist on `eth0`;
  `homelab-fw-edge` adds redundant iptables drops for Kubernetes-specific
  ports (`10250` kubelet, `4789` VXLAN, `30000-32767` NodePort) on the
  public interface as defence in depth.
- The `edge-guardrail` allowlist permits SSH from a single home admin IP.
  That IP is operator-specific (currently `82.123.119.181`). It is **not**
  committed to Git; the rebuild flow expects the operator to set
  `ADMIN_SSH_ALLOW_IP` in `firewall/edge-allowlist.env` before applying.
  See the env example file.

## rp_filter caveat

Both `sysctl/99-k3s-calico.conf` and `bootstrap/wireguard/99-wireguard.conf`
set rp_filter values, and they overlap. The net effect, after both files
load (alphabetical order, `wireguard` last):

| Key | Value | Set by |
|---|---|---|
| `net.ipv4.conf.all.rp_filter` | `2` | `99-wireguard.conf` (last write wins) |
| `net.ipv4.conf.default.rp_filter` | `2` | `99-wireguard.conf` |
| `net.ipv4.conf.wg0.rp_filter` | `0` | `99-k3s-calico.conf` (only file that sets it for wg0) |

This is intentional. Calico VXLAN encapsulation creates asymmetric paths on
`wg0` that strict rp_filter would drop. Loose rp_filter on `wg0` plus the
default value of `2` everywhere else is the right balance.

## See also

- `../wireguard/README.md` -- Layer 1 (private mesh)
- `../k3s/README.md` -- Layer 2 (Kubernetes base)
- `../../dr/RUNBOOK.md` -- the operator's command-by-command rebuild path
- `MANIFEST.md` -- exact file-to-path mapping per node
