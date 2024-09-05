# Reverse Proxy Gateway Setup with Wireguard VPN

## Cloud VM Setup

### Initial Setup

1. **Login as Root**:
   ```bash
   sudo su -
   ```

2. **Update the System**:
   ```bash
   dnf update && dnf upgrade -y
   ```

3. **Set Hostname**:
   ```bash
   hostnamectl set-hostname cloud-vm
   ```

4. **Edit the Hosts File**:
   Add the following entry to `/etc/hosts`:
   ```bash
   echo "<CLOUD-VM-IP> cloud-vm cloud-vm.kakde.eu" >> /etc/hosts
   ```

### Install Essential Packages

Install necessary packages for system security and VPN setup:
```bash
apt install sudo logrotate fail2ban wireguard ufw
```

### Firewall Configuration

Configure UFW to allow essential ports and services:

```bash
ufw allow ssh
ufw allow http
ufw allow https
ufw allow 51820/udp
ufw allow 51821/udp
ufw allow 2024/tcp
ufw enable
ufw status
```

### Enable Services

Enable the services to start automatically on boot:

```bash
systemctl enable ufw
systemctl enable fail2ban
systemctl enable wireguard
```

### User Management

Add two new users and configure their SSH access:

```bash
sudo adduser aniket --gecos "" --disabled-password && echo "aniket:password" | sudo chpasswd && sudo usermod -aG sudo aniket
sudo adduser ansible --gecos "" --disabled-password && echo "ansible:password" | sudo chpasswd && sudo usermod -aG sudo ansible
```

Switch to the `aniket` user:

```bash
su - aniket
```

Copy your SSH public key to the remote server:

```bash
echo "ssh-ed25519 <PUBLIC-KEY id_ed25519.pub>" >> ~/.ssh/authorized_keys
```

### SSH Configuration

In case you made some error you can revert it hence open new terminal and try to connect instead of closing down currently connected ssh session before running these commands.

Secure the SSH server by modifying `/etc/ssh/sshd_config`:

```bash
sudo sed -i '/^#Port 22/s/^#//;s/Port 22/Port 2024/; /^#PasswordAuthentication yes/s/^#//;s/PasswordAuthentication yes/PasswordAuthentication no/; /^#PermitRootLogin yes/s/^#//;s/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
```

Now you could test login via from another terminal:
```bash
ssh aniket@<CLOUD-VM-IP> -p 2024
```

---

## WireGuard VPN Setup

**Setting Up a WireGuard VPN on Debian (Cloud VM) and AlmaLinux (Local Machines: `node-01` and `node-02`)**

This guide provides detailed instructions for setting up a WireGuard VPN between a remote AlmaLinux 9 server (`cloud-vm`) and two AlmaLinux 9 client nodes (`node-01` and `node-02`). The guide covers installation, configuration, and optional routing of client traffic through the VPN server.

### Step 1: Set Up WireGuard on the Remote Server (`cloud-vm`)

#### 1.1 Install WireGuard
First, log into your Debian 12 server and install WireGuard using the `apt` package manager. Root access is required, so either switch to the root user or prepend the commands with `sudo`.

Login as root: `su -` otherwise use sudo everywhere to run following command:

```bash
dnf update && dnf upgrade -y
dnf install epel-release -y
dnf install wireguard-tools -y
```

#### 1.2 Generate Server Keys on the Cloud VM
Generate the server's private and public keys. For each VPN interface, create separate key pairs.

```bash
wg genkey | tee /etc/wireguard/privatekey.cloud-vm-wg0 | wg pubkey | tee /etc/wireguard/publickey.cloud-vm-wg0
chmod 400 /etc/wireguard/privatekey.cloud-vm-wg0
```

#### 1.3 Create WireGuard Configuration Files
Create and edit the WireGuard configuration files for both interfaces:

```bash
sudo nano /etc/wireguard/wg0.conf
```

Add the following configuration for `wg0`:

```ini
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = <privatekey.cloud-vm-wg0>

#### IP forwarding rules
#PostUp = iptables -t nat -I POSTROUTING -o eth0 -j MASQUERADE
#PostUp = iptables -A FORWARD -i %i -j ACCEPT
#PostUp = iptables -A FORWARD -o %i -j ACCEPT
#PreDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
#PreDown = iptables -D FORWARD -i %i -j ACCEPT
#PreDown = iptables -D FORWARD -o %i -j ACCEPT

[Peer]
PublicKey = <publickey.node-01-wg0>
AllowedIPs = 10.0.0.2/32

[Peer]
PublicKey = <publickey.node-02-wg0>
AllowedIPs = 10.0.0.3/32
```

**Note**: Replace `<privatekey.cloud-vm-wg0>`, `<privatekey.cloud-vm-wg0>`, `<publickey.node-01-wg0>`, and `<publickey.node-02-wg0>` with the actual keys you generated earlier.

#### 1.4 Configure Firewall on the Cloud VM
Allow the WireGuard ports through the firewall:

```bash
firewall-cmd --zone=public --permanent --add-port=51820/udp
firewall-cmd --permanent --zone=public --add-masquerade
firewall-cmd --reload
```

#### 1.6 Start and Enable WireGuard
Start and enable the WireGuard interfaces:

```bash
systemctl start wg-quick@wg0
systemctl enable wg-quick@wg0
```

---

### Step 2: Set Up WireGuard on the Clients (`node-01` and `node-02`)

### 2.1 Install WireGuard
On each client, enable the Extra Packages for Enterprise Linux (EPEL) repository and install WireGuard:

Login as root via: `su -` otherwise use sudo everywhere to run following command:

```bash
dnf install epel-release -y
dnf install wireguard-tools -y
```

### 2.2 Generate Client Keys

**For `node-01`:**

```bash
wg genkey | tee /etc/wireguard/privatekey.node-01-wg0 | wg pubkey | tee /etc/wireguard/publickey.node-01-wg0
sudo chmod 400 /etc/wireguard/privatekey.node-01-wg0
```

**For `node-02`:**

```bash
wg genkey | tee /etc/wireguard/privatekey.node-02-wg0 | wg pubkey | tee /etc/wireguard/publickey.node-02-wg0
chmod 400 /etc/wireguard/privatekey.node-02-wg0
```

### 2.3 Configure Firewall
Allow the necessary WireGuard ports on the clients:

**For `node-01`:**

```bash
firewall-cmd --zone=public --permanent --add-port=51820/udp
firewall-cmd --reload
```

**For `node-02`:**

```bash
firewall-cmd --zone=public --permanent --add-port=51820/udp
firewall-cmd --reload
```

### 2.4 Load WireGuard Kernel Module
Ensure the WireGuard kernel module is loaded on both clients:

```bash
modprobe wireguard
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

**For `node-01`:**

Create and edit the configuration file:

```bash
nano /etc/wireguard/wg0.conf
```

Add the following configuration:

```ini
[Interface]
PrivateKey = <privatekey.node-01-wg0>
Address = 10.0.0.2/32

[Peer]
PublicKey = <publickey.cloud-vm-wg0>
Endpoint = <CLOUD-VM-IP>:51820
AllowedIPs = 10.0.0.1/32
PersistentKeepalive = 25
```

**For `node-02`:**

Create and edit the configuration file:

```bash
nano /etc/wireguard/wg0.conf
```

Add the following configuration:

```ini
[Interface]
PrivateKey = <privatekey.node-02-wg0>
Address = 10.0.0.3/32

[Peer]
PublicKey = <publickey.cloud-vm-wg0>
Endpoint = <CLOUD-VM-IP>:51821
AllowedIPs = 10.0.0.1/32
PersistentKeepalive = 25
```

**Note**: Replace `<privatekey.node-01-wg0>`, `<privatekey.node-02-wg0>`, `<publickey.cloud-vm-wg0>`, `<publickey.cloud-vm-wg0>`, and `<server-public-ip>` with your actual keys and the server’s public IP address.

### 2.6 Start and Enable WireGuard
Start and enable the WireGuard service on both clients:

```bash
systemctl start wg-quick@wg0
systemctl enable wg-quick@wg0
```

---

#### In case you would like to Redirect all the traffic from client to through the wireguard tunnel then follow following steps:

- Enable IP forwarding on the server by modifying the `sysctl` configuration:

```bash
sed -i 's/^# *net\.ipv4\.ip_forward = 1/net\.ipv4\.ip_forward = 1/' /etc/sysctl.conf
sysctl -p
```

- Change `AllowedIPs = 0.0.0.0/0` in wg0.conf and wg1.conf at the Clients Machine.

- And Uncomment the `IP forwarding rules` block for PreDown and PostUp configuration on the Cloud VM.

---

# Reverse Proxy Gateway Setup with NGINX

Currently used instructions at [4. nginx-setup.md](./4. nginx-setup.md). 

---


(IGNORE BELOW THIS. JUST NOTES)

### Install Certbot and NGINX

Install Certbot for obtaining SSL certificates and NGINX for web serving:

```bash
apt install certbot python3-certbot-nginx
systemctl enable nginx
```

### Configure NGINX for Let's Encrypt

1. **Create Let's Encrypt Configuration**:
   ```bash
   touch /etc/nginx/snippets/letsencrypt.conf
   echo "location ^~ /.well-known/acme-challenge/ {
       default_type \"text/plain\";
       root /var/www/letsencrypt;
   }" > /etc/nginx/snippets/letsencrypt.conf
   ```

2. **Create the Directory**:
   ```bash
   mkdir /var/www/letsencrypt
   ```

3. **Configure NGINX for HTTP**:
   Create and edit the file `/etc/nginx/sites-enabled/kakde.eu`:

   ```bash
   touch /etc/nginx/sites-enabled/kakde.eu
   echo "server {
       listen 80;
       include /etc/nginx/snippets/letsencrypt.conf;
       server_name kakde.eu www.kakde.eu;
       root /var/www/kakde.eu;
       index index.html;
   }" > /etc/nginx/sites-enabled/kakde.eu
   ```

4. **Verify and Reload NGINX**:
   ```bash
   nginx -t
   systemctl reload nginx
   ```

### Fetch and Deploy SSL Certificate

1. **Obtain Certificate**:
   ```bash
   certbot --nginx -d kakde.eu -d www.kakde.eu
   ```

2. **Verify Configuration**:
   After obtaining the certificate, the `/etc/nginx/sites-enabled/kakde.eu` file will be updated automatically by Certbot.

3. **Enable Auto Renew**:
   Add the following lines to crontab (`crontab -e`) to renew certificates automatically:

   ```bash
   30 2 * * 1 /usr/bin/certbot renew >> /var/log/certbot_renew.log 2>&1
   35 2 * * 1 /etc/init.d/nginx reload
   ```

### Redirect HTTP to HTTPS and Non-WWW to WWW

Edit the NGINX configuration to redirect all HTTP requests to HTTPS and non-WWW URLs to WWW:

```bash
mv /etc/nginx/sites-enabled/kakde.eu kakde.eu.initial.config
nano /etc/nginx/sites-enabled/kakde.eu
```

Replace the content with the following:

```nginx
# Redirect HTTP to HTTPS and non-WWW to WWW
server {
    listen 80;
    include /etc/nginx/snippets/letsencrypt.conf;
    server_name kakde.eu www.kakde.eu;
    location / {
        return 301 https://kakde.eu$request_uri;
    }
}

# HTTPS server for WWW redirect and upstream proxy
upstream backend {
    server 10.0.0.3:30000;  # node-02
}

server {
    listen 443 ssl; 
    ssl_certificate /etc/letsencrypt/live/kakde.eu/fullchain.pem; 
    ssl_certificate_key /etc/letsencrypt/live/kakde.eu/privkey.pem; 
    include /etc/letsencrypt/options-ssl-nginx.conf; 
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; 
    server_name kakde.eu;

    location / {
        proxy_pass http://backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

---