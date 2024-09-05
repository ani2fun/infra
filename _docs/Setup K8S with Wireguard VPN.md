# Setting Up a Kubernetes Cluster with K3s, WireGuard VPN, Calico CNI, and MetalLB on Hybrid Infrastructure

---

## **Table of Contents**

1. [Introduction](#introduction)
2. [Infrastructure Overview](#infrastructure-overview)
3. [Preparing the Environment](#preparing-the-environment)
    - 3.1 [Updating System Packages](#31-updating-system-packages)
    - 3.2 [Setting Hostnames](#32-setting-hostnames)
    - 3.3 [Configuring SSH Access](#33-configuring-ssh-access)
    - 3.4 [Configuring SELinux](#34-configuring-selinux)
    - 3.5 [Router Networking Setup](#35-router-networking-setup)
    - 3.6 [Setting Up Firewall Rules](#36-setting-up-firewall-rules)
4. [Setting Up WireGuard VPN](#setting-up-wireguard-vpn)
    - 4.1 [Installing WireGuard](#41-installing-wireguard)
    - 4.2 [Generating WireGuard Keys](#42-generating-wireguard-keys)
    - 4.3 [Configuring WireGuard](#43-configuring-wireguard)
    - 4.4 [Starting WireGuard](#44-starting-wireguard)
    - 4.5 [Verifying the VPN Mesh](#45-verifying-the-vpn-mesh)
    - 4.6 [Enabling IP Forwarding](#46-enabling-ip-forwarding)
5. [Installing K3s](#installing-k3s)
    - 5.1 [Install K3s on the Control Plane (master-01)](#51-install-k3s-on-the-control-plane-master-01)
    - 5.2 [Install K3s on Worker Nodes](#52-install-k3s-on-worker-nodes)
6. [Installing MetalLB](#installing-metallb)
    - 6.1 [Deploy MetalLB](#61-deploy-metallb)
    - 6.2 [Configure MetalLB](#62-configure-metallb)
7. [Installing Nginx Ingress Controller Via Helm](#installing-nginx-ingress-controller-via-helm)
    - 7.1 [Install Nginx Ingress Controller](#71-install-nginx-ingress-controller)
    - 7.2 [Nginx as a Reverse Proxy on Cloud-VM](#72-nginx-as-a-reverse-proxy-on-cloud-vm)
8. [Securing the Ingress Using Cert-Manager](#securing-the-ingress-using-cert-manager)
    - 8.1 [Setting Up Cert-Manager for TLS Certificates](#81-setting-up-cert-manager-for-tls-certificates)
    - 8.2 [Create a ClusterIssuer](#82-create-a-clusterissuer)
9. [Uninstalling K3S](#uninstalling-k3s)
    - 9.1 [From Master](#91-from-master)
    - 9.2 [From Worker Nodes](#92-from-worker-nodes)
    - 9.3 [Verify Uninstallation](#93-verify-uninstallation)
    - 9.4 [Clean Up Any Leftover Configuration (Optional)](#94-clean-up-any-leftover-configuration-optional)

---

## **Introduction**

Guide for setting up Kubernetes cluster using K3s, a lightweight Kubernetes distribution ideal for resource-constrained environments. The setup will include WireGuard VPN for secure communication between nodes and forming WireGuard VPN mesh, Calico CNI for networking, and MetalLB for load balancing. Additionally, we will configure an Nginx Ingress Controller for routing HTTP/HTTPS traffic and integrate Cert-Manager for managing TLS certificates via Let's Encrypt.

- **[Wireguard](https://www.wireguard.com) VPN Mesh:** Provides secure communication between master-01, worker-01, and cloud-vm.
    - **Full Mesh Network:** Each node (master-01, worker-01, cloud-vm) is both a hub and a spoke. This means every node has a direct peer connection with every other node. This setup reduces reliance on any single node, improving fault tolerance and reducing packet loss.
- **[K3S](https://docs.k3s.io/)**: Lightweight Kubernetes. Easy to install, half the memory, all in a binary of less than 100 MB.
- **[Calico CNI](https://docs.tigera.io/calico/latest/about/):** Manages network policies and pod networking in the Kubernetes cluster.
- **[MetalLB](https://metallb.universe.tf/):** Provides LoadBalancer services, assigning IPs from the IP range that you define.
- **[NGINX Ingress Controller](https://docs.nginx.com/nginx-ingress-controller/overview/about/):** Manages external access to your Kubernetes services.
    - [Kubernetes Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/): Manages routing within the K8s cluster, directing traffic to the appropriate services.
- **[Cloudflare DNS](https://developers.cloudflare.com/dns/concepts/):** Directs traffic to your cloud-vm.
- **[NGINX on cloud-vm](https://docs.nginx.com/nginx/admin-guide/web-server/reverse-proxy/):** Acts as a reverse proxy, forwarding HTTP/HTTPS traffic to your Kubernetes cluster over the VPN.

---

## **Infrastructure Overview**

`master-01` and `worker-01` are behind an ISP router, which assigns a different public IP address than the nodes themselves. WireGuard is used to establish a VPN mesh, with `cloud-vm` serving as the entry point for external traffic. `cloud-vm` has a public IP address and will handle all external traffic redirected from Cloudflare, to domain `example.com`.

Our setup includes the following components:

(ISP = Internet Service Provider)

| **Node Name**                   | **Role**                   | **Private IP Address**                       | **WireGuard IP** | **Public IP Address** | **Notes**                                               |
|---------------------------------|----------------------------|----------------------------------------------|------------------|-----------------------|---------------------------------------------------------|
| `master-01`                     | Master Node(Control Plane) | 192.168.5.3 (Local IP Address by ISP router) | 10.0.0.1         | HOME_ROUTER_PUBLIC_IP | Located behind behind ISP home router                   |
| `worker-01`                     | Worker Node                | 192.168.5.4 (Local IP Address by ISP router) | 10.0.1.1         | HOME_ROUTER_PUBLIC_IP | Located behind behind ISP home router                   |
| `cloud-vm`                      | Worker Node                | 10.0.2.1                                     | 10.0.2.1         | CLOUD_VM_PUBLIC_IP    | VM hosted on <CLOUD, e.g DigitalOcean> with a public IP |
| -----------------------------   | ---------------            | --------------                               | --------------   | -------               |                                                         |
| **Local Jumpbox Machine**       |
| ------------------------------- | -----------------          | ----------------                             | ---------------- | ---------             |                                                         |
| `Local (Mac/Linux/Windows)`     | NONE                       | 192.168.5.5 (Local IP Address by ISP router) | **NONE**         |                       |                                                         |
| -----------------------------   | ---------------            | --------------                               | --------------   | -------               |                                                         |


**Operating System**: AlmaLinux 9.4

**Primary Goals**:
- Establish secure communication between nodes using WireGuard VPN.
- Set up a resilient and secure Kubernetes cluster.
- Utilize Calico for network policy management.
- Deploy MetalLB to enable LoadBalancer services on bare-metal setups.
- Implement TLS termination using Nginx Ingress and Cert-Manager.

---

## **Preparing the Environment**

### **3.1 Updating System Packages**

Before proceeding, update the system packages on all nodes:

```bash
sudo dnf update && sudo dnf upgrade -y
sudo dnf install net-tools -y
```

### **3.2 Setting Hostnames**

- Set the hostname for each node:

```bash
sudo hostnamectl set-hostname master-01.example.com
sudo hostnamectl set-hostname worker-01.example.com
sudo hostnamectl set-hostname cloud-vm.example.com
```

- Restart the hostname service to apply changes:

```bash
sudo systemctl restart systemd-hostnamed
```

### **3.3 Configuring SSH Access**

- Generate SSH keys on each node (if not already generated).

```bash
sudo ssh-keygen -t ed25519 -C "<user-name>@<node-name>"
```

- Copy your Jumpbox's public key e.g. `~/.ssh/id_ed25519.pub"` to the authorized keys `~/.ssh/authorized_keys` file on the remote nodes to enable passwordless SSH access. This will ease your access to machines from your jumpbox machine for ssh access:

- (Optional) If you want to enable a root access then:
    - Edit the SSH configuration file: `nano /etc/ssh/sshd_config`
    - Set `PermitRootLogin` to `yes` and restart the SSH service.
    - Restart sshd : `systemctl restart sshd`

---

### **3.4 Configuring SELinux**
- Most documentation recommends setting SELinux to permissive or disabling it until all security policy concerns are addressed.
- Edit the SELinux configuration file: `vi /etc/selinux/config` and set `SELINUX=permissive` or `SELINUX=disabled`.
- If you modify the SELinux settings, reboot the system for the changes to take effect.

### **3.5 Router Networking Setup**
As Currently this is hybrid environment, where cloud-vm is VPS hosted in the Contabo cloud VPS server and my local home network, we need to take of certain networking scenarios. Local Home network is served with router of my internet provider. So it has different public ip assigned. Behind this router on my home network is created. The private ip addresses is assigned by my router. Better to assign static ip address for the machine master-01 and worker-01.

- Do **UDP** port forwarding from router ip port **51820** to machine's port **51820** for master-01 node for wireguard.
- Do **UDP** port forwarding from router ip port **52820** to machine's port **51820** for worker-01 node for wireguard.
- For example, if your Public IP address of router is: <ROUTER_PUBLIC_IP>, then open up different port and forward it to correct machines.
    - <ROUTER_PUBLIC_IP>:**51820** forwarded to <PRIVATE_IP_MASTER_01>:51820
    - <ROUTER_PUBLIC_IP>:**52820** forwarded to <PRIVATE_IP_WORKER_01>:51820

### **3.6 Setting Up Firewall Rules**
To ensure secure and proper communication between the nodes, configure the firewall on each node. Some of the rules may not be needed please adjust as per your requirements.

Zone info: https://firewalld.org/documentation/zone/predefined-zones.html
- **Public Zone:** This zone is for public-facing services and ports. Masquerading is enabled to ensure proper network address translation (NAT), which is essential for routing traffic from private to public networks.
- **Trusted Zone:** This zone is for internal communication between trusted networks, such as your VPN and Kubernetes pod and service networks. It ensures that the necessary traffic can flow freely between nodes.

Please configure it as per your need.

- **Public Zone Configuration:**
```bash
# Ports
sudo firewall-cmd --zone=public --permanent --add-port=51820/udp # Add WireGuard VPN port on all nodes.
sudo firewall-cmd --zone=public --permanent --add-port=80/tcp # For HTTP external traffic (Required only for cloud-vm).
sudo firewall-cmd --zone=public --permanent --add-port=443/tcp # For HTTPS external traffic (Required only for cloud-vm).
#sudo firewall-cmd --zone=public --permanent --add-port=6443/tcp # Add Kubernetes API server port (if required).
#sudo firewall-cmd --zone=public --permanent --add-port=10250-10257/tcp # Add ports for Kubelet and metrics server communication (if required).
#sudo firewall-cmd --zone=public --permanent --add-port=30000-32767/tcp # Add NodePort range for Kubernetes services (if required).
   
# Services
sudo firewall-cmd --zone=public --permanent --add-service=ssh # Allow SSH access.
sudo firewall-cmd --zone=public --permanent --add-service=wireguard # Allow WireGuard service.
sudo firewall-cmd --zone=public --permanent --add-service=dns # Allow DNS services (optional, adjust based on your needs).

# Enable masquerading for proper network address translation
sudo firewall-cmd --zone=public --permanent --add-masquerade

# Reload firewall to apply changes
sudo firewall-cmd --reload
```

- **Trusted Zone Configuration:**
```bash
# Ports
sudo firewall-cmd --zone=trusted --permanent --add-port=51820/udp # Add WireGuard VPN port on all nodes.
sudo firewall-cmd --zone=trusted --permanent --add-port=80/tcp # For HTTP external traffic
sudo firewall-cmd --zone=trusted --permanent --add-port=443/tcp # For HTTPS external traffic
sudo firewall-cmd --zone=trusted --permanent --add-port=6443/tcp # Add Kubernetes API server port
sudo firewall-cmd --zone=trusted --permanent --add-port=10250-10257/tcp # Add ports for Kubelet and metrics server communication
sudo firewall-cmd --zone=trusted --permanent --add-port=30000-32767/tcp # Add NodePort range for Kubernetes services
# sudo firewall-cmd --zone=trusted --permanent --add-port=2379-2380/tcp # If etcd used

# Add specific subnet under trusted for internal communication requirements
sudo firewall-cmd --zone=trusted --permanent --add-source=10.0.0.0/16 # Allow traffic from WireGuard VPN network
sudo firewall-cmd --zone=trusted --permanent --add-source=10.43.0.0/16 # Allow traffic from the Service network
sudo firewall-cmd --zone=trusted --permanent --add-source=172.16.0.0/12 # Allow traffic from the Pod network (adjust CIDR if needed for Calico CNI)

# Reload firewall to apply changes
sudo firewall-cmd --reload
```

---

## **Setting Up WireGuard VPN**

WireGuard will create a secure VPN mesh between the nodes, allowing them to communicate over private IP addresses.

### **4.1 Installing WireGuard**

- Install WireGuard on all nodes:

```bash
sudo dnf install epel-release -y
sudo dnf install wireguard-tools -y
```

- Load WireGuard Kernel Module.
    - Ensure the WireGuard kernel module is loaded on all nodes:
        - ```bash
            modprobe wireguard
            lsmod | grep wireguard
          ```
        - If the module is loaded, you should see output similar to:
            - ```console
          wireguard             118784  0
          ip6_udp_tunnel         16384  1 wireguard
          udp_tunnel             28672  1 wireguard
          curve25519_x86_64      36864  1 wireguard
          libcurve25519_generic  49152  2 curve25519_x86_64,wireguard
            ```

### **4.2 Generating WireGuard Keys**

Generate the WireGuard keys on each node:

- **On each node, generate private and public keys.**
    - On **cloud-vm**
         ```bash
            wg genkey | tee /etc/wireguard/privatekey.cloud-vm-wg0 | wg pubkey | tee /etc/wireguard/publickey.cloud-vm-wg0
            sudo chmod 400 /etc/wireguard/privatekey.cloud-vm-wg0
         ```
    - On **master-01**
        ```bash
           wg genkey | tee /etc/wireguard/privatekey.master-01-wg0 | wg pubkey | tee /etc/wireguard/publickey.master-01-wg0
           sudo chmod 400 /etc/wireguard/privatekey.master-01-wg0
        ```
    - On **worker-01**
        ```bash
           wg genkey | tee /etc/wireguard/privatekey.worker-01-wg0 | wg pubkey | tee /etc/wireguard/publickey.worker-01-wg0
           sudo chmod 400 /etc/wireguard/privatekey.worker-01-wg0
        ```

### **4.3 Configuring WireGuard**

- Create the WireGuard configuration file `/etc/wireguard/wg0.conf` on each node.
- (Optional) To set **MTU** value, subtract 80 bytes from your network interface's MTU (e.g., for a 1500 MTU interface, use 1420). This allows for Wireguard encryption overhead.

#### **master-01 (Control Plane)**

```ini
[Interface]
PrivateKey = <MASTER_01_PRIVATE_KEY>
Address = 10.0.0.1/24 # Assign the IP address 10.0.0.1 to the master node.
ListenPort = 51820

# Peer: cloud-vm
[Peer]
PublicKey = <CLOUD_VM_PUBLIC_KEY>
Endpoint = <CLOUD_VM_PUBLIC_IP>:51820
AllowedIPs = 10.0.2.0/24 # Allow entire 10.0.2.X subnet.
PersistentKeepalive = 25

# Peer: worker-01
[Peer]
PublicKey = <WORKER_01_PUBLIC_KEY>
Endpoint = <LOCAL_IP>:51820 # 192.168.5.4
AllowedIPs = 10.0.1.0/24 # Allow entire 10.0.1.X subnet.
PersistentKeepalive = 25
```

#### **worker-01 (Worker Node)**

```ini
[Interface]
PrivateKey = <WORKER_01_PRIVATE_KEY>
Address = 10.0.1.1/24 # Assign the IP address 10.0.1.1 to the master node.
ListenPort = 51820

# Peer: cloud-vm
[Peer]
PublicKey = <CLOUD_VM_PUBLIC_KEY>
Endpoint = <CLOUD_VM_PUBLIC_IP>:51820
AllowedIPs = 10.0.2.0/24 # Allow entire 10.0.2.X subnet.
PersistentKeepalive = 25

# Peer: master-01
[Peer]
PublicKey = <MASTER_01_PUBLIC_KEY>
Endpoint = <LOCAL_IP>:51820 # 192.168.5.3
AllowedIPs = 10.0.0.0/24 # Allow entire 10.0.0.X subnet.
PersistentKeepalive = 25
```

#### **cloud-vm (Worker Node on VM)**

```ini
[Interface]
PrivateKey = <CLOUD_VM_PRIVATE_KEY>
Address = 10.0.2.1/24 # Assign 10.0.2.1 IP to cloud-vm
ListenPort = 51820

# Peer: master-01
[Peer]
PublicKey = <MASTER_01_PUBLIC_KEY>
Endpoint = <ROUTERS_PUBLIC_IP>:51820 # Port Forwarding: The router's port 51820 is mapped to the master's port 51820.
AllowedIPs = 10.0.0.0/24 # Allow entire 10.0.0.X subnet.
PersistentKeepalive = 25

# Peer: worker-01
[Peer]
PublicKey = <WORKER_01_PUBLIC_KEY>
Endpoint = <ROUTERS_PUBLIC_IP>:52820 # Port Forwarding: The router's port 52820 is mapped to the worker's port 51820.
AllowedIPs = 10.0.1.0/24 # Allow entire 10.0.1.X subnet.
PersistentKeepalive = 25
```

**PersistentKeepalive ensures that NAT mappings stay active, which is especially important for nodes behind NAT.**

### **4.4 Starting WireGuard**

**Start and Enable WireGuard on all nodes:**

```bash
sudo systemctl start wg-quick@wg0
sudo systemctl enable wg-quick@wg0
```

### **4.5 Verifying the VPN Mesh**

- **Check the handshake status on each node:**
```bash
wg show
```

- **(Optional) If ICMP protocol is disabled then enable it in firewall on all nodes:**
```bash
sudo

 firewall-cmd --permanent --zone=trusted --remove-icmp-block=echo-reply
sudo firewall-cmd --permanent --zone=trusted --remove-icmp-block=echo-request
sudo firewall-cmd --permanent --zone=trusted --remove-icmp-block-inversion
sudo firewall-cmd --reload
```

- **Verify connectivity between the nodes using `ping`. **ssh** into the respective nodes and using ping verify packet transfer.**
- **From cloud-vm TO** -->
    - master-01: `ping 10.0.0.1 -c 4`
    - worker-01: `ping 10.0.1.1 -c 4`
- **From master-01 TO** -->
    - worker-01: `ping 10.0.1.1 -c 4`
    - cloud-vm: `ping 10.0.2.1 -c 4`
- **From worker-01 TO** -->
    - master-01: `ping 10.0.0.1 -c 4`
    - cloud-vm: `ping 10.0.2.1 -c 4`

**Make sure to not have any packet loss.**

---

### **4.6 Enabling IP Forwarding**

**Enable IP forwarding on all nodes:**

```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

## **Installing K3s**

**K3s is a lightweight Kubernetes distribution that is easy to deploy and manage.**

### **5.1 Install K3s on the Control Plane (master-01)**

Here **k3s-resolv.conf**  is added for appropriate DNS Resolution:

- **Create and Edit `nano /etc/k3s-resolv.conf` with content of nameservers:**

```bash
sudo tee /etc/k3s-resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 8.8.4.4
nameserver 1.0.0.1
EOF
```

**Install K3s with Calico as the CNI:**

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
--node-ip=10.0.0.1 \
--flannel-backend=none \
--disable-network-policy \
--disable=traefik \
--resolv-conf=/etc/k3s-resolv.conf \
--tls-san=api.example.com \
--tls-san=10.0.2.1 \
--advertise-address=10.0.0.1" sh -
```

**Explanation of params:**

- --node-ip=10.0.0.1: The internal WireGuard IP for master-01.
- --flannel-backend=none: Disables Flannel since we will use Calico.
- --disable-network-policy: Disables the default network policy controller.
- --disable=traefik: Disables Traefik as NGINX Ingress Controller will be used.
- --resolv-conf=/etc/resolv.conf: Ensures proper DNS settings.
- --tls-san=api.example.com: Includes the API domain in the TLS SANs for secure access.
- --tls-san=10.0.2.1: Includes the internal IP of cloud-vm to allow secure internal access.
- --advertise-address=10.0.0.1: Advertises the internal IP of master-01 for the API server.

---

#### **(Optional Read)**

**Understanding and Configuring TLS SANs (Subject Alternative Names)**

TLS SANs (Subject Alternative Names) are a critical component in securing your Kubernetes cluster, particularly when you plan to access the Kubernetes API server or other services externally using a domain name.

1. What are TLS SANs?

SANs are extensions to the X.509 specification that allow you to specify additional hostnames, IP addresses, or DNS names that should be included in the SSL/TLS certificate. When a client (e.g., kubectl, a browser, or another service) connects to a server, it checks whether the hostname or IP address it’s connecting to matches any of the SANs in the server’s certificate. If it doesn’t match, the connection is not considered secure.

**Why --tls-san=*.example.com is Not Ideal**
- Wildcard SAN Limitation: Including `--tls-san=*.example.com` might seem like it covers all subdomains, but it does not directly provide the precision needed for the API server. The API server needs to match the exact hostname or IP being accessed.
- Client Connections: When clients (e.g., kubectl) connect to api.example.com, they expect the certificate to have that specific hostname in the SANs, not a wildcard.

**Why are TLS SANs ?**

With cloud-vm being the entry point for external traffic and handling a domain like example.com, TLS SANs ensure that:
- Secure Access to Kubernetes API: If you plan to access the Kubernetes API externally using a domain name like api.example.com, this domain needs to be included in the SANs of the certificate used by the API server.
- Multiple Access Points: If your API server is accessible via multiple IPs, hostnames, or domain names (e.g., api.example.com, 10.0.0.1, etc.), all these should be covered by the SANs.
- Cert-Manager and Ingress: When Cert-Manager issues certificates for your services, it will create certificates with SANs that match the hostnames specified in your Ingress resources.

**SAN Configuration for K3s API Server**

Given current setup and the need for proper certificate management:
Use Specific SANs:
--tls-san=api.example.com: Includes the domain name you will use to access the API server. This ensures that when you access the API server via api.example.com, the certificate matches.
--tls-san=<CLOUD_VM_PUBLIC_IP>: Include the public IP of cloud-vm if you need to access the API server via IP.
--tls-san=10.0.2.1: Include the internal WireGuard IP if internal services or nodes access the API server using this IP.

---

### **When installation is successful:**

```bash
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
source ~/.bashrc
```

**If `kubectl` is not installed on the master-01 node then install it via:**
- **Download the latest release with the command:**
```bash
 curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
```
- **Install kubectl: / [Installation documentation for `kubectl`](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)**
```bash
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

**After installation, check that `master-01` is up and running as the control plane:**

```bash
kubectl get nodes -o wide
```

**Should See **NotReady** because we have not implemented yet CNI Policy.**

```console
[root@master-01 ~]# nodes
NAME                 STATUS     ROLES                  AGE     VERSION        INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION                 CONTAINER-RUNTIME
master-01.example.com   NotReady   control-plane,master   3m57s   v1.30.4+k3s1   10.0.0.1      <none>        AlmaLinux 9.4 (Seafoam Ocelot)   5.14.0-427.31.1.el9_4.x86_64   containerd://1.7.20-k3s1
```

### **Install Calico CNI on master-01** :

1. **Apply Calico Manifest:**

**Since the node was `NotReady`, we applied Calico CNI to handle networking:**

```bash
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

---

### **5.2 Install K3s on Worker Nodes**

**Get the server token from the `master-01`:**

```bash
cat /var/lib/rancher/k3s/server/node-token
```

**Install K3s on `worker-01`:**

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://10.0.0.1:6443 K3S_TOKEN=<K3S_TOKEN> INSTALL_K3S_EXEC="agent \
--node-ip=10.0.1.1 \
--resolv-conf=/etc/k3s-resolv.conf" sh -
```

**Install K3s on `cloud-vm`:**

```bash
curl -sfL https://get.k3s.io | K3S_URL=https://10.0.0.1:6443 K3S_TOKEN=<K3S_TOKEN> INSTALL_K3S_EXEC="agent \
--node-ip=10.0.2.1 \
--resolv-conf=/etc/k3s-resolv.conf \
--node-external-ip=185.230.138.134" sh -
```

**Explanation of params:**

- --node-ip=10.0.1.1: Internal IP for worker-01.
- --node-ip=10.0.2.1: Internal IP for cloud-vm.
- --node-external-ip=<CLOUD_VM_PUBLIC_IP>: Specifies the public IP for cloud-vm, ensuring it can serve external traffic.


**Verify the cluster nodes:**

```bash
kubectl get nodes -o wide
```

**Expected output:**

```console
NAME                 STATUS   ROLES                  AGE   VERSION        INTERNAL-IP   EXTERNAL-IP       OS-IMAGE                         KERNEL-VERSION                 CONTAINER-RUNTIME
cloud-vm.example.com    Ready    <none>                 46h   v1.30.4+k3s1   10.0.2.1      185.230.138.134   AlmaLinux 9.4 (Seafoam Ocelot)   5.14.0-427.31.1.el9_4.x86_64   containerd://1.7.20-k3s1
master-01.example.com   Ready    control-plane,master   46h   v1.30.4+k3s1   10.0.0.1      <none>            AlmaLinux 9.4 (Seafoam Ocelot)   5.14.0-427.31.1.el9_4.x86_64   containerd://1.7.20-k3s1
worker-01.example.com   Ready    <none>                 46h   v1.30.4+k3s1   10.0.1.1      <none>            AlmaLinux 9.4 (Seafoam Ocelot)   5.14.0-427.31.1.el9_4.x86_64   containerd://1.7.20-k3s1
```

**Verify Pods Working as expected:**

```bash
kubectl get pods -o wide
```

---

### **Installing MetalLB**

### **6.1 Deploy MetalLB**

**Install MetalLB in the cluster:**

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
```

**Check the status:**
```bash
kubectl -n metallb-system get svc
kubectl -n metallb-system get pods
kubectl api-resources | grep metallb
```

**Expected output:**
```text
NAME                      TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
metallb-webhook-service   ClusterIP   10.43.159.103   <none>        443/TCP   44h

NAME                          READY   STATUS    RESTARTS   AGE
controller-6dd967fdc7-hl5wj   1/1     Running   0          44h
speaker-f4mn8                 1/1     Running   0          44h
speaker-wfspw                 1/1     Running   0          44h
speaker-zdqqj                 1/1     Running   0          44h

bfdprofiles                                      metallb.io/v1beta1                true         BFDProfile
bgpadvertisements                                metallb.io/v1beta1                true         BGPAdvertisement
bgppeers                                         metallb.io/v1beta2                true         BGPPeer
communities                                      metallb.io/v1beta1                true         Community
ipaddresspools                                   metallb.io/v1beta1                true         IPAddressPool
l2advertisements                                 metallb.io/v1beta1                true         L2Advertisement
servicel2statuses                                metallb.io/v1beta1                true         ServiceL2Status
```

### **6.2 Configure MetalLB**

**Create an IP address pool:**

```bash
cat <<EOF > first-pool.yaml
# first-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
    - 172.16.100.10-172.16.100.20
EOF
```

**Roll out the configuration:**

```bash
kubectl create -f first-pool.yaml
```

**Create an L2 Advertisement:**
```bash
cat <<EOF > l2advertisement.yaml
# l2advertisement.yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - first-pool
EOF
```

**Roll out the L2 Advertisement:**

```bash
kubectl create -f l2advertisement.yaml
```

**Verify if the MetalLB is working as expected. To test, create a service of type LoadBalancer::**

```bash
cat <<EOF > kuard-k8s-first.yaml
apiVersion: v1
kind: Service
metadata:
  name: kuard-k8s-first
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
  selector:
    app: kuard-k8s-first
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kuard-k8s-first
spec:
  selector:
    matchLabels:
      app: kuard-k8s-first
  replicas: 1
  template:
    metadata:
      labels:
        app: kuard-k8s-first
    spec:
      containers:
        - name: kuard-container
          image: gcr.io/kuar-demo/kuard-amd64:1
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
      nodeSelector:
        kubernetes.io/hostname: master-01.example.com
EOF
```

**Roll out:**

```bash
kubectl create -f kuard-k8s-first.yaml
```

**Check services in default namespace**
```bash
kubectl get svc -n default
```

**Expected output for the service:**

```text
[root@master-01 ~]# k get svc
NAME                        TYPE           CLUSTER-IP      EXTERNAL-IP     PORT(S)                      AGE
kubernetes                  ClusterIP      10.43.0.1       <none>          443/TCP                      47h
kuard-k8s-first             LoadBalancer   10.43.8.169     172.16.100.10   80:31375/TCP,443:30567/TCP   5h46m
```

- **For `kuard-k8s-first` Service, there needs to External IP address assigned automatically by MetalLB.**

- **It shows that MetalLB load balancer is working as expected.**

---

## **Installing Nginx Ingress Controller Via Helm**

### **7.1 Install Nginx Ingress Controller**

**First add Nginx Ingress Controller's repository to Helm by running:**

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
```

**First add its repository:**
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

**Expected output:**
```text
...
...
Update Complete. ⎈Happy Helming!⎈
```

**Following command installs the Nginx Ingress Controller from the stable charts repository, names the Helm release nginx-ingress, and sets the publishService parameter to true.**
```bash
helm install nginx-ingress ingress-nginx/ingress-nginx --set controller.publishService.enabled=true
```

**Expected output of the install command:**

```text
Output
NAME: nginx-ingress
LAST DEPLOYED: Mon Sep  2 11:40:28 2024
NAMESPACE: default
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
...
```

**Run this command to watch `-w` the Load Balancer become available:**

```bash
kubectl --namespace default get services -o wide -w nginx-ingress-ingress-nginx-controller
```

**After some time has passed, MetalLB will assign a External IP address to the Service automatically for newly created Load Balancer:**

**Expected output:**
```text
NAME                                     TYPE           CLUSTER-IP    EXTERNAL-IP     PORT(S)                      AGE     SELECTOR
nginx-ingress-ingress-nginx-controller   LoadBalancer   10.43.8.169   172.16.100.11   80:31375/TCP,443:30567/TCP   5h55m   app.kubernetes.io/component=controller,app.kubernetes.io/instance=nginx-ingress,app.kubernetes.io/name=ingress-nginx
```

**When it is successful it means we are ready for our next steps.**

### **7.2 Nginx as a Reverse Proxy on Cloud-VM**

It's only purpose is to forward http and https traffic for our domain `example.com` to the LoadBalancer service `nginx-ingress-ingress-nginx-controller`.

We are going to use CloudVM's Public IP, as master-01 and worker-01 do not have their own dedicated public IPs. Instead, they are behind a NAT (Network Address Translation) on your ISP-provided router. This means the public IP visible to the outside world is the router's IP, not the IP of master-01 or worker-01. Cloud-VM is our Entry point and this is the IP address we have assigned in our DNS provider (Cloudflare) settings.

### **First create a Nginx reverse proxy on cloud-vm:**

```bash
dnf install nginx -y
```

**Verify that the directory `/etc/nginx/sites-available` exists. If it does not, create it using the following command:**
```bash
sudo mkdir -p /etc/nginx/sites-available
```

**Next, create a file named `default` using the following command:**
```bash
sudo tee /etc/nginx/sites-available/default <<EOF
# NGINX reverse proxy configuration on cloud-vm

server {
    listen 80;
    server_name example.com *.example.com;

    location / {
        proxy_pass http://172.16.100.11; # # Forward to LoadBalancer service `nginx-ingress-ingress-nginx-controller`.
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 443 ssl;
    server_name example.com *.example.com;

    # These directives will simply forward the SSL traffic to the Ingress Controller without terminating it
    location / {
        proxy_pass http://172.16.100.11; # Forward to LoadBalancer service `nginx-ingress-ingress-nginx-controller`.
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
```

**Then verify and reload nginx:**

```bash
sudo nginx -t
sudo systemctl nginx reload 
```

**Create an Ingress resource to expose the Kuard application:**

```bash
cat <<EOF > kuard-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kuard-k8s-ingress
spec:
  ingressClassName: nginx
  rules:
    - host: "kuard1.example.com"
      http:
        paths:
          - path: "/"
            pathType: Prefix
            backend:
              service:
                name: kuard-k8s-first
                port:
                  number: 80
EOF
```

**Roll out:**
```bash
kubectl create -f kuard-ingress.yaml
```

and Check in your browsers incognito mode: http://kuard1.example.com for the

---

## **Securing the Ingress Using Cert-Manager**

### **8.1 Setting Up Cert-Manager for TLS Certificates**

Cert-Manager automates the management of TLS certificates.

1. **Install Cert-Manager**

Add and Update Repo for Cert-Manager using Helm:

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

Install Cert-Manager into the cert-manager namespace by running the following command:

```bash
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.15.3 --set crds.enabled=true
```

```text
Output
NAME: cert-manager
LAST DEPLOYED: Wed Sept 2 19:46:39 2024
NAMESPACE: cert-manager
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
cert-manager v1.15.3 has been deployed successfully!
...
```

The `NOTES` of the output (which has been truncated in the display above) states that you need to set up an Issuer to issue TLS certificates.

---

### **8.2 Create a ClusterIssuer**

```bash
cat <<EOF > prod-clusterissuer-http01.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-http01
spec:
  acme:
    # Email address used for ACME registration
    email: email@example.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      # Name of a secret used to store the ACME account private key
      name: letsencrypt-prod-http01-private-key
    # Add a single challenge solver, HTTP01 using nginx
    solvers:
      - http01:
          ingress:
            class: nginx
EOF
```

This configuration defines a ClusterIssuer that contacts Let’s Encrypt in order to issue certificates. You’ll need to replace your_email_address with your email address to receive any notices regarding the security and expiration of your certificates.


**Roll out with kubectl:**
```bash
kubectl apply -f prod-clusterissuer-http01.yaml
```

**You should see the following output:**

```text
Output
clusterissuer.cert-manager.io/letsencrypt-prod-http01
```

**Edit the previously created `kuard-ingress.yaml` file to include the ClusterIssuer information:**

The updated file should look something like this:

```bash
cat <<EOF > prod-clusterissuer-http01.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kuard-k8s-ingress
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod-http01
spec:
  ingressClassName: nginx
  tls:
    - hosts:
      - kuard1.example.com
      secretName: kuard-k8s-tls
  rules:
    - host: "kuard1.example.com"
      http:
        paths:
          - path: "/"
            pathType: Prefix
            backend:
              service:
                name: kuard-k8s-first
                port:
                  number: 80
EOF
```

The tls block under spec defines what Secret will store the certificates for your sites (listed under hosts), which the letsencrypt-prod-http01 ClusterIssuer issues. The secretName must be different for every Ingress you create.

**Roll out with kubectl:**
```bash
kubectl apply -f prod-clusterissuer-http01.yaml
```

**Expected output:**
```text
Output
ingress.networking.k8s.io/hello-kubernetes-ingress configured
```

Wait a few minutes for the Let’s Encrypt servers to issue a certificate for your domains. In the meantime, you can track progress by inspecting the output of the following command:

```bash
kubectl describe certificate kuard-k8s-tls
```

The end of the output will be similar to this:

```text
...
Output
Events:
Type    Reason     Age    From                                       Message
  ----    ------     ----   ----                                       -------
Normal  Issuing    2m34s  cert-manager-certificates-trigger          Issuing certificate as Secret does not exist
Normal  Generated  2m34s  cert-manager-certificates-key-manager      Stored new private key in temporary Secret resource "kuard-k8s-tls-jkdgg"
Normal  Requested  2m34s  cert-manager-certificates-request-manager  Created new CertificateRequest resource "kuard-k8s-tls-dkllg"
Normal  Issuing    2m7s   cert-manager-certificates-issuing          The certificate has been successfully issued
```

- **When the last line of output reads The certificate has been successfully issued, you can exit by pressing CTRL + C.**

- **Now visit the website from your web browser https://kuard1.example.com**

---

## **Uninstalling K3S**

### **9.1 From Master**
- **Uninstall K3s on master-01:**
```bash
/usr/local/bin/k3s-uninstall.sh
```
- **This command will remove K3s and all of its components, including the `kubectl` configuration and data files.**

### **9.2 From Worker Nodes**
- **Uninstall K3s on worker nodes:**
```bash
/usr/local/bin/k3s-agent-uninstall.sh
```
- **This command will remove K3s agent and all related components from the worker nodes.**

### **9.3 Verify Uninstallation**

- **On each node, ensure that K3s has been completely removed by checking if the K3s services are no longer running:**
```bash
sudo systemctl status k3s
sudo systemctl status k3s-agent
```
Both commands should return "Unit k3s.service could not be found" or similar messages indicating that the services are no longer present.

### 9.4 Clean Up Any Leftover Configuration (Optional)
- If you wish to clean up any leftover configuration files or directories manually on their respective nodes, then you can remove them using:
  ```bash
  rm -rf /usr/local/bin/k3s
  rm -rf /etc/rancher/k3s/
  rm -rf /var/lib/rancher/k3s
  rm -rf /etc/systemd/system/k3s.service
  rm -rf /etc/systemd/system/k3s-agent.service
  ```
After completing these steps, K3s should be fully uninstalled from your nodes.

