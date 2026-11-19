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

`<HOME_WAN_IP>` is the home router's WAN address. It is operator-specific
and dynamic -- the ISP rotates it -- so it is not committed here. Read it
with `curl -4 -fsS https://ifconfig.me` **from the home LAN** (`-4`
because plain `curl` may answer with IPv6), or from
`ADMIN_SSH_ALLOW_IP` in `/etc/edge-allowlist.env` on vm-1, which is the
same address with a `/32` suffix.

- `<HOME_WAN_IP>:51820/udp -> wk-1:51820/udp`
- `<HOME_WAN_IP>:51821/udp -> ms-1:51820/udp`
- `<HOME_WAN_IP>:51822/udp -> wk-2:51820/udp`

Only `vm-1.wg0.conf.example` needs this value: the home nodes dial out to
vm-1's static Contabo address, so they carry no `<HOME_WAN_IP>` endpoint.

