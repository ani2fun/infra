# Setting Up a WireGuard VPN on Debian (Cloud VM) and AlmaLinux (Local Machines: `master-01` and `worker-01`)

This guide provides detailed instructions for setting up a WireGuard VPN between a remote Debian 12 server (`gw-vpn-server`) and two AlmaLinux 9 client nodes (`master-01` and `worker-01`). The guide covers installation, configuration, and optional routing of client traffic through the VPN server.

## Step 1: Set Up WireGuard on the Remote Server (`gw-vpn-server`)

### 1.1 Install WireGuard
First, log into your Debian 12 server and install WireGuard using the `apt` package manager. Root access is required, so either switch to the root user or prepend the commands with `sudo`.

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install wireguard
```

### 1.2 Generate Server Keys on the Cloud VM
Generate the server's private and public keys. For each VPN interface, create separate key pairs.

```bash
wg genkey | sudo tee /etc/wireguard/privatekey.gw-vpn-server-wg0 | wg pubkey | sudo tee /etc/wireguard/publickey.gw-vpn-server-wg0
chmod 400 /etc/wireguard/privatekey.gw-vpn-server-wg0
```

Repeat the process for the second interface (`wg1`):

```bash
wg genkey | sudo tee /etc/wireguard/privatekey.gw-vpn-server-wg1 | wg pubkey | sudo tee /etc/wireguard/publickey.gw-vpn-server-wg1
chmod 400 /etc/wireguard/privatekey.gw-vpn-server-wg1
```

### 1.3 Create WireGuard Configuration Files
Create and edit the WireGuard configuration files for both interfaces:

```bash
sudo nano /etc/wireguard/wg0.conf
```

Add the following configuration for `wg0`:

```ini
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = <privatekey.gw-vpn-server-wg0>

# IP forwarding rules
PostUp = iptables -t nat -I POSTROUTING -o eth0 -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -j ACCEPT
PreDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
PreDown = iptables -D FORWARD -i %i -j ACCEPT
PreDown = iptables -D FORWARD -o %i -j ACCEPT

[Peer]
PublicKey = <publickey.master-01-wg0>
AllowedIPs = 10.0.0.2/32
```

Create the configuration file for `wg1`:

```bash
sudo nano /etc/wireguard/wg1.conf
```

Add the following configuration for `wg1`:

```ini
[Interface]
Address = 10.0.1.1/24
ListenPort = 51821
PrivateKey = <privatekey.gw-vpn-server-wg1>

# IP forwarding rules
PostUp = iptables -t nat -I POSTROUTING -o eth0 -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -j ACCEPT
PreDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
PreDown = iptables -D FORWARD -i %i -j ACCEPT
PreDown = iptables -D FORWARD -o %i -j ACCEPT

[Peer]
PublicKey = <publickey.worker-01-wg1>
AllowedIPs = 10.0.1.2/32
```

**Note**: Replace `<privatekey.gw-vpn-server-wg0>`, `<privatekey.gw-vpn-server-wg1>`, `<publickey.master-01-wg0>`, and `<publickey.worker-01-wg1>` with the actual keys you generated earlier.

### 1.4 Configure Firewall on the Cloud VM
Allow the WireGuard ports through the firewall:

```bash
sudo ufw allow 51820/udp
sudo ufw allow 51821/udp
sudo ufw disable
sudo ufw enable
sudo ufw status
```

### 1.5 Enable IP Forwarding on the Server
Enable IP forwarding on the server by modifying the `sysctl` configuration:

```bash
sudo sed -i 's/^# *net\.ipv4\.ip_forward = 1/net\.ipv4\.ip_forward = 1/' /etc/sysctl.conf
sudo sysctl -p
```

### 1.6 Start and Enable WireGuard
Start and enable the WireGuard interfaces:

```bash
sudo systemctl start wg-quick@wg0
sudo systemctl enable wg-quick@wg0
```

```bash
sudo systemctl start wg-quick@wg1
sudo systemctl enable wg-quick@wg1
```

---

## Step 2: Set Up WireGuard on the Clients (`master-01` and `worker-01`)

### 2.1 Install WireGuard
On each client, enable the Extra Packages for Enterprise Linux (EPEL) repository and install WireGuard:

```bash
sudo dnf install epel-release -y
sudo dnf install wireguard-tools -y
```

### 2.2 Generate Client Keys

**For `master-01`:**

```bash
wg genkey | sudo tee /etc/wireguard/privatekey.master-01-wg0 | wg pubkey | sudo tee /etc/wireguard/publickey.master-01-wg0
sudo chmod 400 /etc/wireguard/privatekey.master-01-wg0
```

**For `worker-01`:**

```bash
wg genkey | sudo tee /etc/wireguard/privatekey.worker-01-wg1 | wg pubkey | sudo tee /etc/wireguard/publickey.worker-01-wg1
sudo chmod 400 /etc/wireguard/privatekey.worker-01-wg1
```

### 2.3 Configure Firewall
Allow the necessary WireGuard ports on the clients:

**For `master-01`:**

```bash
sudo firewall-cmd --zone=public --permanent --add-port=51820/udp
sudo firewall-cmd --reload
```

**For `worker-01`:**

```bash
sudo firewall-cmd --zone=public --permanent --add-port=51821/udp
sudo firewall-cmd --reload
```

### 2.4 Load WireGuard Kernel Module
Ensure the WireGuard kernel module is loaded on both clients:

```bash
sudo modprobe wireguard
lsmod | grep wireguard
```

If the module is loaded, you should see output similar to:

```bash
wireguard             118784  0
ip6_udp_tunnel         16384  1 wireguard
udp_tunnel             28672  1 wireguard
curve25519_x86_64      36864  1 wireguard
libcurve25519_generic  49152  2 curve25519_x86_64,wireguard
```

### 2.5 Create WireGuard Configuration Files

**For `master-01`:**

Create and edit the configuration file:

```bash
sudo nano /etc/wireguard/wg0.conf
```

Add the following configuration:

```ini
[Interface]
PrivateKey = <privatekey.master-01-wg0>
Address = 10.0.0.2/32

[Peer]
PublicKey = <publickey.gw-vpn-server-wg0>
Endpoint = <server-public-ip>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

**For `worker-01`:**

Create and edit the configuration file:

```bash
sudo nano /etc/wireguard/wg1.conf
```

Add the following configuration:

```ini
[Interface]
PrivateKey = <privatekey.worker-01-wg1>
Address = 10.0.1.2/32

[Peer]
PublicKey = <publickey.gw-vpn-server-wg1>
Endpoint = <server-public-ip>:51821
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

**Note**: Replace `<privatekey.master-01-wg0>`, `<privatekey.worker-01-wg1>`, `<publickey.gw-vpn-server-wg0>`, `<publickey.gw-vpn-server-wg1>`, and `<server-public-ip>` with your actual keys and the server’s public IP address.

### 2.6 Start and Enable WireGuard
Start and enable the WireGuard service on both clients:

```bash
sudo systemctl start wg-quick@wg0
sudo systemctl enable wg-quick@wg0
```

For `worker-01`, use:

```bash
sudo systemctl start wg-quick@wg1
sudo systemctl enable wg-quick@wg1
```

---

