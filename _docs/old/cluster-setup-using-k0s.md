# Two-Node Kubernetes Cluster Setup Using k0s

Deploying a two-node Kubernetes cluster using k0s on AlmaLinux. The setup involves configuring two nodes as both control plane and worker nodes, along with detailed instructions for firewall and network configurations.

## Prerequisites

### Hardware and Network

- **Two Nodes**: `master-01.kakde.eu` and `worker-01.kakde.eu`
- **Operating System**: AlmaLinux 9 (or any compatible RHEL-based distribution)
- **Network Configuration**: Ensure both nodes can communicate over the network.
- **User Access**: Root access or the ability to use `sudo` is required on both nodes.
- **SSH Access**: Set up SSH key-based authentication between the nodes and your local machine for secure access.

To include the information about the `/etc/hosts` file on the Jumpbox machine, you should add it to the **Environment Setup** section. This section is where you define the setup details, including the network configuration. Here's how you can update the documentation:

---

## Environment Setup

| Role          | Hostname           | IP Address             |
|---------------|--------------------|------------------------|
| Jumpbox       | Jumpbox            | IP address of Jumpbox  |
| Control Plane | master-01.kakde.eu | INTERNAL_IP            |
| Worker Node   | worker-01.kakde.eu | INTERNAL_IP            |
| Worker Node   | cloud-vm.kakde.eu  | PUBLIC_IP              |

To update the documentation with the necessary `/etc/hosts` file information for `master-01` and `worker-01`, follow these steps. You should add this information to the section where you're preparing the nodes, particularly under network configuration or as a dedicated step.

#### **1. Jumpbox**

```bash
# WIFI
# 192.168.1.130 worker-01.kakde.eu worker-01
<INTERNAL_IP> master-01.kakde.eu master-01

# enp171s0 ethernet ip address for worker-01
<INTERNAL_IP> worker-01.kakde.eu worker-01

# Remote Gateway
<PUBLIC_IP> cloud-vm cloud-vm.kakde.eu
```

#### **2. Node Configuration (master-01 and worker-01)**

### 1.6 Configure `/etc/hosts` on Kubernetes Nodes

Ensure that the `/etc/hosts` file on both `master-01` and `worker-01` includes the following entries for proper DNS resolution within the Kubernetes cluster:

**On `master-01.kakde.eu` and `worker-01.kakde.eu`:**

```bash
<INTERNAL_IP> master-01.kakde.eu master-01
<INTERNAL_IP>  worker-01.kakde.eu worker-01
```

---

## Step 1: Prepare the Nodes

### 1.1 System Update and Essential Packages

1. **Update the System**:
   ```bash
   sudo dnf update -y
   sudo dnf upgrade -y
   ```

2. **Install Essential Packages**:
   ```bash
   sudo dnf install -y epel-release
   sudo dnf install -y vim curl wget net-tools firewalld
   ```

3. **Reboot the System** (if necessary):
   ```bash
   sudo reboot
   ```

### 1.2 Network and SELinux Configuration

1. **Configure SELinux** (if you need to disable or adjust it):
   ```bash
   sudo vi /etc/selinux/config
   ```
  - Set `SELINUX=permissive` or `SELINUX=disabled` based on your requirements.
  - Reboot the system if you change SELinux settings.

2. **Check Network Interfaces**:
   ```bash
   ifconfig
   ```
   Ensure the interfaces (`enp171s0`, etc.) are configured correctly.

### 1.3 SSH Configuration

1. **Generate SSH Key** (if not already generated):
   ```bash
   ssh-keygen -t ed25519 -C "root@worker-01"
   ```

2. **Copy SSH Keys to Nodes**:
   ```bash
   cat ~/.ssh/id_ed25519.pub | ssh root@master-01.kakde.eu 'cat >> ~/.ssh/authorized_keys'
   cat ~/.ssh/id_ed25519.pub | ssh root@worker-01.kakde.eu 'cat >> ~/.ssh/authorized_keys'
   ```

3. **Enable Root Login on Nodes**:
   Edit the SSH configuration file:
   ```bash
   sudo nano /etc/ssh/sshd_config
   ```
   Set `PermitRootLogin` to `yes` and restart the SSH service:
   ```bash
   sudo systemctl restart sshd
   ```

### 1.4 Set Hostnames on Nodes

On `master-01`:
```bash
hostnamectl set-hostname master-01.kakde.eu
systemctl restart systemd-hostnamed
```

On `worker-01`:
```bash
hostnamectl set-hostname worker-01.kakde.eu
systemctl restart systemd-hostnamed
```

### 1.5 Tune System Performance

1. **Enable and Start Tuned**:
   ```bash
   sudo systemctl start tuned
   sudo systemctl enable tuned
   ```

2. **Verify Tuned Settings**:
   ```bash
   tuned-adm list
   tuned-adm active
   ```

---

## Step 2: Firewall Configuration

### 2.1 Configure Firewall Ports

Run the following commands to configure the firewall on both `master-01` and `worker-01`:

```bash
# Allow traffic for Kubernetes API server
sudo firewall-cmd --zone=public --permanent --add-port=6443/tcp

# Allow traffic for etcd (client and peer communication)
sudo firewall-cmd --zone=public --permanent --add-port=2379-2380/tcp

# Allow traffic for kubelet
sudo firewall-cmd --zone=public --permanent --add-port=10250-10256/tcp

# Allow traffic for NodePort services
sudo firewall-cmd --zone=public --permanent --add-port=30000-32767/tcp

# Allow traffic for Konnectivity
sudo firewall-cmd --zone=public --permanent --add-port=8132/tcp

# Allow traffic for Overlay network (VXLAN for Calico)
sudo firewall-cmd --zone=public --permanent --add-port=4789/udp

# Allow traffic for CoreDNS
sudo firewall-cmd --zone=public --permanent --add-port=53/tcp
sudo firewall-cmd --zone=public --permanent --add-port=53/udp

# Allow traffic for Ingress Controller
sudo firewall-cmd --zone=public --permanent --add-port=80/tcp
sudo firewall-cmd --zone=public --permanent --add-port=443/tcp

# Add sources for Pod and Service CIDRs
sudo firewall-cmd --zone=public --permanent --add-source=10.244.0.0/16
sudo firewall-cmd --zone=public --permanent --add-source=10.96.0.0/12

# Add network interfaces based on the hosts `enp171s0` (Replace this with what you see using `ifconfig` for the network interface).
sudo firewall-cmd --zone=public --add-interface=enp171s0 --permanent
sudo firewall-cmd --zone=public --add-interface=eth0 --permanent
sudo firewall-cmd --zone=public --add-interface=wg0 --permanent

# Allow traffic for Calico BGP (optional)
sudo firewall-cmd --zone=public --permanent --add-port=179/tcp
sudo firewall-cmd --zone=public --permanent --add-port=179/udp

# Apply masquerade (for NAT and IP forwarding)
sudo firewall-cmd --zone=public --permanent --add-masquerade

# Reload firewall to apply changes
sudo firewall-cmd --reload

```

### 2.2 Validate Firewall Configuration

Verify that the firewall rules are correctly configured:

```bash
sudo firewall-cmd --list-all
```

---

## Step 3: Install k0s on Both Nodes

### 3.1 Download and Install k0s

On both `master-01` and `worker-01`, install `k0s`:

```bash
curl -sSLf https://get.k0s.sh | sudo sh
```

### 3.2 Verify Installation

Check the `k0s` installation by verifying the version:

```bash
k0s version
```

---

## Step 4: Create and Apply k0sctl Configuration

### 4.1 Install k0sctl on Jumpbox (MacOS)

On your local machine (Jumpbox), install `k0sctl`:

```bash
brew install k0sproject/tap/k0sctl
```

### 4.2 Create k0sctl Configuration File

Generate a `k0sctl.yaml` file with the following content:

```yaml
---
apiVersion: k0sctl.k0sproject.io/v1beta1
kind: Cluster
metadata:
  name: k0s-cluster
spec:
  hosts:
    - role: controller+worker
      ssh:
        address: master-01.kakde.eu
        user: root
        port: 22
        keyPath: /path/to/your/ssh/key
    - role: controller+worker
      ssh:
        address: worker-01.kakde.eu
        user: root
        port: 22
        keyPath: /path/to/your/ssh/key
  k0s:
    version: "1.30.3+k0s.0"
    config:
      apiVersion: k0s.k0sproject.io/v1beta1
      kind: ClusterConfig
      spec:
        storage:
          type: etcd
          etcd:
            peerAddresses:
              - https://master-01.kakde.eu:2379
              - https://worker-01.kakde.eu:2379
        network:
          provider: calico
          calico:
            mode: Overlay
            mtu: 1450
```

### 4.3 Apply the Configuration

Apply the configuration to deploy the k0s cluster on both nodes:

```bash
k0sctl apply --config k0sctl.yaml
```

This will deploy the k0s cluster on both nodes.

---

## Step 5: Configure the Cluster

### 5.1 Remove Taints to Enable Workloads on Controllers

To allow workloads to run on both controller nodes, remove the default taint:

```bash
kubectl taint nodes master-01.kakde.eu node-role.kubernetes.io/master:NoSchedule-
kubectl taint nodes worker-01.kakde.eu node-role.kubernetes.io/master:NoSchedule-
```

### 5.2 Verify Node and Pod Status

1. **Check Node Status**:
   ```bash
   kubectl get nodes
   ```

2. **Verify Pod

**Deployment**:
Deploy a simple test application to ensure everything is functioning.
You can test the deployment by creating an Nginx deployment:

1. **Create Nginx Deployment YAML**:
    ```bash
    cat <<EOF > nginx-deployment.yaml
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: nginx-service
    spec:
      type: NodePort
      ports:
        - port: 80
          targetPort: 80
          nodePort: 30000
      selector:
        app: nginx
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: nginx-deployment
      labels:
        app: nginx
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: nginx
      template:
        metadata:
          labels:
            app: nginx
        spec:
          containers:
            - name: nginx
              image: nginx:1.27
              ports:
                - containerPort: 80
              resources:
                requests:
                  memory: "64Mi"
                  cpu: "250m"
                limits:
                  memory: "128Mi"
                  cpu: "500m"
              readinessProbe:
                httpGet:
                  path: /
                  port: 80
                initialDelaySeconds: 5
                periodSeconds: 10
              livenessProbe:
                httpGet:
                  path: /
                  port: 80
                initialDelaySeconds: 15
                periodSeconds: 20
    EOF
    ```

2. **Apply the YAML File**:
    ```bash
    kubectl apply -f nginx-deployment.yaml
    ```

3. **Access the Nginx Service**:
   Open your browser and navigate to `http://worker-01.kakde.eu:30000/`.

Access the application by using the NodePort assigned to the nginx service.

### 5.3 Configure kubectl Access

Export the kubeconfig file to access the cluster:

```bash
k0sctl kubeconfig > kubeconfig
export KUBECONFIG=$PWD/kubeconfig
```

To make this permanent, add the export command to your `.zshrc` or `.bashrc` file.

---