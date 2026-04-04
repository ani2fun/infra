# WireGuard bootstrap

These templates are reconstructed from `_docs/setup-wireguard.md`.

## What is still missing

- The private keys are intentionally not stored here.
- The live public keys from each node were not exported in this session.
- Replace each placeholder before applying the config.

## Apply on each node

1. Install WireGuard packages.
2. Generate `/etc/wireguard/wg0.key` and derive the public key.
3. Copy the matching `*.conf.example` file to `/etc/wireguard/wg0.conf`.
4. Replace the placeholders.
5. Install `99-wireguard.conf` into `/etc/sysctl.d/`.
6. Run `sysctl --system`.
7. Run `chmod 600 /etc/wireguard/wg0.conf /etc/wireguard/wg0.key`.
8. Run `systemctl enable --now wg-quick@wg0`.

## Router requirements

- `82.123.119.181:51820/udp -> wk-1:51820/udp`
- `82.123.119.181:51821/udp -> ms-1:51820/udp`
- `82.123.119.181:51822/udp -> wk-2:51820/udp`

