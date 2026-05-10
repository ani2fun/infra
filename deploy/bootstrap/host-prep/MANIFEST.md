# Host preparation file manifest

Exact file-to-path mapping per node. The `prepare-host.sh` script applies
these automatically based on the node's hostname; this manifest is the
human-readable reference.

## Files installed on every node

| Source in repo | Target path on node |
|---|---|
| `sysctl/99-k3s-calico.conf` | `/etc/sysctl.d/99-k3s-calico.conf` |
| `../wireguard/99-wireguard.conf` (existing) | `/etc/sysctl.d/99-wireguard.conf` |
| `modules-load/k3s-calico.conf` | `/etc/modules-load.d/k3s-calico.conf` |

## Home nodes only (ms-1, wk-1, wk-2)

| Source | Target |
|---|---|
| `modules-load/k8s.conf` | `/etc/modules-load.d/k8s.conf` |
| `ssh/99-root-login.conf` | `/etc/ssh/sshd_config.d/99-root-login.conf` |
| `netplan/<hostname>.yaml.example` | `/etc/netplan/01-network-manager-all.yaml` and/or `/etc/netplan/50-cloud-init.yaml` |

## ms-1 only

| Source | Target |
|---|---|
| `firewall/homelab-fw-ms1.sh` | `/usr/local/sbin/homelab-fw-ms1.sh` (mode 0755) |
| `firewall/homelab-fw-ms1.service` | `/etc/systemd/system/homelab-fw-ms1.service` |
| `firewall/k3s-api-lockdown.sh` | `/usr/local/sbin/k3s-api-lockdown.sh` (mode 0755) |
| `firewall/k3s-api-lockdown.service` | `/etc/systemd/system/k3s-api-lockdown.service` |
| `firewall/k3s-api-lockdown-allow-cluster.service` | `/etc/systemd/system/k3s-api-lockdown-allow-cluster.service` |

After install: `systemctl enable --now homelab-fw-ms1.service
k3s-api-lockdown.service k3s-api-lockdown-allow-cluster.service`.

## vm-1 (ctb-edge-1) only

| Source | Target |
|---|---|
| `sysctl/10-panic.conf` | `/etc/sysctl.d/10-panic.conf` (preserved Contabo image setting) |
| `sysctl/99-cloudimg-ipv6.conf` | `/etc/sysctl.d/99-cloudimg-ipv6.conf` (preserved Contabo image setting) |
| `ssh/60-cloudimg-settings.conf` | `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf` |
| `netplan/vm-1.yaml.example` | `/etc/netplan/50-cloud-init.yaml` |
| `firewall/homelab-fw-edge.sh` | `/usr/local/sbin/homelab-fw-edge.sh` (mode 0755) |
| `firewall/homelab-fw-edge.service` | `/etc/systemd/system/homelab-fw-edge.service` |
| `firewall/edge-allowlist.env.example` | `/etc/edge-allowlist.env` (operator fills in `ADMIN_SSH_ALLOW_IP`) |
| `../../platform/traefik/edge-guardrail.sh` (existing) | `/usr/local/sbin/edge-guardrail.sh` |
| `../../platform/traefik/edge-guardrail.service` (existing) | `/etc/systemd/system/edge-guardrail.service` |

After install: `systemctl enable --now homelab-fw-edge.service
edge-guardrail.service`.

## wk-2 specific

`netplan/wk-2.yaml.example` ships a wired Ethernet block by default with a
clearly marked, commented-out Wi-Fi block including a
`<<REPLACE_WITH_WIFI_PSK>>` placeholder. If wk-2 must stay on Wi-Fi:

1. Copy the example to `/etc/netplan/50-cloud-init.yaml`.
2. Uncomment the Wi-Fi block.
3. Replace `<<REPLACE_WITH_WIFI_PSK>>` with the live PSK from the password
   manager.
4. `chmod 600 /etc/netplan/50-cloud-init.yaml`.
5. `netplan generate && netplan apply`.

NTP daemon on wk-2 is `chronyd`, not `systemd-timesyncd`. The prep script
detects the hostname and installs the right one.

## Apply order on a fresh node

1. Install Ubuntu 24.04.4 LTS, set hostname to one of `ms-1` / `wk-1` /
   `wk-2` / `ctb-edge-1`.
2. Add an SSH key for `root` so the operator can SSH in (LAN for home,
   Contabo console for vm-1 -- the public allowlist isn't applied yet).
3. Copy this directory to the node (e.g. `scp -r host-prep root@ms-1:`).
4. SSH in as root, `cd host-prep/`, run `./prepare-host.sh`.
5. Inspect the verification block at the end of the script's output.
6. Reboot if the script printed a "kernel update pending" notice.
7. Proceed to `../wireguard/README.md`.
