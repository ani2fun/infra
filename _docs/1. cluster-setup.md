This guide walks you through deploying a k0s Kubernetes cluster on AlmaLinux 9 using the `k0sctl` tool. The setup includes a control plane node and a worker node. Since AlmaLinux is binary compatible with RHEL, these instructions
should also work on Rocky Linux 9 and RHEL.

(Note: In my scenario, Jumpbox machine is MacOS, while the other two nodes run AlmaLinux 9.4.)

## Reference

For more details, refer to the official k0sctl install
guide: [k0sctl install guide](https://docs.k0sproject.io/stable/k0sctl-install/).

## Environment Setup

| Role          | Hostname              | IP Address            |
|---------------|-----------------------|-----------------------|
| Jumpbox       | Jumpbox               | IP address of Jumpbox |
| Control Plane | master-01.example.com | 192.168.1.120         |
| Worker Node   | worker-01.example.com | 192.168.1.130         |

## Jumpbox Machine Configuration

**Add Nodes IP Addresses to Hosts File**:
```bash
sudo nano /etc/hosts
```

Add IPv4 and Fully qualified domain name (FQDN) in your **/etc/hosts** file. Short Name is (optional) e.g  `master-01` or `worker-01`. 
```
# IPv4        FQDN                  Short Name
192.168.1.120 master-01.example.com master-01
192.168.1.130 worker-01.example.com worker-01
```

**Generate SSH Keys** (if not already generated):

```bash
$ ssh-keygen -t ed25519 -C "Your Comment"
```

**Copy SSH Keys to Nodes**:
From your workspace machine, copy the SSH public key to your clipboard:
Using command: `cat ~/.ssh/id_ed25519.pub`.

```console
ssh-ed25519 <YOUR-KEY-CHARS> <Your Comment>
```

Then on each node, copy this the public key to the `authorized_keys` file:

```bash
sudo echo "ssh-ed25519 <YOUR-KEY-CHARS> <Your Comment>" >> ~/.ssh/authorized_keys
```

**Enable Root Login on Nodes**:
Edit the SSH configuration file:

```bash
sudo nano /etc/ssh/sshd_config
```

Set `PermitRootLogin` to `yes`:

```bash
PermitRootLogin yes
```

Restart the SSH service:

```bash
sudo systemctl restart sshd
```

**Set Hostnames on Nodes**:
On `master-01`:

```bash
hostnamectl set-hostname master-01.example.com
systemctl restart systemd-hostnamed
```

On `worker-01`:

```bash
hostnamectl set-hostname worker-01.example.com
systemctl restart systemd-hostnamed
```

**Enable and Start Cockpit Service on Nodes** (optional):

```bash
sudo systemctl enable --now cockpit.socket
sudo systemctl start cockpit
```

## Firewall Configuration

(You might need adjustments depending on your specific network configuration.)

Configure `firewalld` on both Master and Worker nodes:

**Add Sources Permanently**:

```bash
sudo firewall-cmd --zone=public --permanent --add-source=10.244.0.0/16
sudo firewall-cmd --zone=public --permanent --add-source=10.96.0.0/12
```

**Add Ports Permanently**:

```bash
sudo firewall-cmd --zone=public --permanent --add-port=80/tcp
sudo firewall-cmd --zone=public --permanent --add-port=6443/tcp
sudo firewall-cmd --zone=public --permanent --add-port=8132/tcp
sudo firewall-cmd --zone=public --permanent --add-port=10250/tcp
sudo firewall-cmd --zone=public --permanent --add-port=179/tcp
sudo firewall-cmd --zone=public --permanent --add-port=179/udp
```

**Enable Masquerading Permanently**:

```bash
sudo firewall-cmd --zone=public --permanent --add-masquerade
```

**Reload Firewalld**:

```bash
sudo firewall-cmd --reload
```

**Verify Firewalld Configuration**:

- On `master-01`:

```bash
firewall-cmd --list-all
```

- On `worker-01`:

```bash
firewall-cmd --list-all
```

## Install k0sctl on Jumpbox (MacOS)

**Install k0sctl**:

```bash
brew install k0sproject/tap/k0sctl
```

**Enable Command Completion**:

```bash
k0sctl completion >> /usr/local/share/zsh/site-functions/_k0sctl
k0sctl completion >> /etc/bash_completion.d/k0sctl
```

**Verify k0sctl Installation**:

```bash
k0sctl version
version: v0.18.1
commit: 53248d6
```

## Configure k0s Kubernetes Cluster

**Generate k0sctl Configuration**:

```bash
k0sctl init > k0sctl.yaml
```

**Modify Configuration File**:
Edit the generated `k0sctl.yaml` file to match your environment. Replace `USERNAME` with your username.

```yaml
---
apiVersion: k0sctl.k0sproject.io/v1beta1
kind: Cluster
metadata:
  name: k0s-cluster
spec:
  hosts:
    - ssh:
        address: master-01.example.com
        user: root
        port: 22
        keyPath: /Users/USERNAME/.ssh/id_ed25519 # Private Key path
      role: controller
    - ssh:
        address: worker-01.example.com
        user: root
        port: 22
        keyPath: /Users/USERNAME/.ssh/id_ed25519 # Private Key path
      role: worker
  k0s:
    dynamicConfig: false
...
```

## Create Kubernetes Cluster Using k0sctl

**Apply Configuration**:

```bash
k0sctl apply --config k0sctl.yaml
```

After successful launch similar to following message will be shown in console.

```console

⠀⣿⣿⡇⠀⠀⢀⣴⣾⣿⠟⠁⢸⣿⣿⣿⣿⣿⣿⣿⡿⠛⠁⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀█████████ █████████ ███
⠀⣿⣿⡇⣠⣶⣿⡿⠋⠀⠀⠀⢸⣿⡇⠀⠀⠀⣠⠀⠀⢀⣠⡆⢸⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀███      ███    ███
⠀⣿⣿⣿⣿⣟⠋⠀⠀⠀⠀⠀⢸⣿⡇⠀⢰⣾⣿⠀⠀⣿⣿⡇⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀███          ███    ███
⠀⣿⣿⡏⠻⣿⣷⣤⡀⠀⠀⠀⠸⠛⠁⠀⠸⠋⠁⠀⠀⣿⣿⡇⠈⠉⠉⠉⠉⠉⠉⠉⠉⢹⣿⣿⠀███          ███    ███
⠀⣿⣿⡇⠀⠀⠙⢿⣿⣦⣀⠀⠀⠀⣠⣶⣶⣶⣶⣶⣶⣿⣿⡇⢰⣶⣶⣶⣶⣶⣶⣶⣶⣾⣿⣿⠀█████████    ███    ██████████
k0sctl v0.18.1 Copyright 2023, k0sctl authors.
Anonymized telemetry of usage will be sent to the authors.
By continuing to use k0sctl you agree to these terms:
https://k0sproject.io/licenses/eula
INFO ==> Running phase: Set k0s version
INFO Looking up latest stable k0s version
INFO Using k0s version v1.30.2+k0s.0
INFO ==> Running phase: Connect to hosts
INFO [ssh] master-01.example.com:22: connected
INFO [ssh] worker-01.example.com:22: connected
INFO ==> Running phase: Detect host operating systems
INFO [ssh] worker-01.example.com:22: is running AlmaLinux 9.4 (Seafoam Ocelot)
INFO [ssh] master-01.example.com:22: is running AlmaLinux 9.4 (Seafoam Ocelot)
INFO ==> Running phase: Acquire exclusive host lock
INFO ==> Running phase: Prepare hosts
INFO ==> Running phase: Gather host facts
INFO [ssh] master-01.example.com:22: using master-01.example.com as hostname
INFO [ssh] worker-01.example.com:22: using worker-01.example.com as hostname
INFO [ssh] master-01.example.com:22: discovered wlp2s0 as private interface
INFO [ssh] master-01.example.com:22: discovered 192.168.1.120 as private address
INFO [ssh] worker-01.example.com:22: discovered wlo1 as private interface
INFO [ssh] worker-01.example.com:22: discovered 192.168.1.130 as private address
INFO ==> Running phase: Validate hosts
INFO ==> Running phase: Gather k0s facts
INFO [ssh] master-01.example.com:22: found existing configuration
INFO [ssh] master-01.example.com:22: is running k0s controller version v1.30.2+k0s.0
INFO [ssh] master-01.example.com:22: listing etcd members
INFO [ssh] worker-01.example.com:22: is running k0s worker version v1.30.2+k0s.0
INFO [ssh] master-01.example.com:22: checking if worker worker-01.example.com has joined
INFO ==> Running phase: Validate facts
INFO [ssh] master-01.example.com:22: validating configuration
INFO ==> Running phase: Release exclusive host lock
INFO ==> Running phase: Disconnect from hosts
INFO ==> Finished in 6s
INFO k0s cluster version v1.30.2+k0s.0 is now installed
INFO Tip: To access the cluster you can now fetch the admin kubeconfig using:
INFO      k0sctl kubeconfig


Fetch Admin Kubeconfig:
After successful completion, fetch the admin kubeconfig:

> k0sctl kubeconfig

```

### Configure kubectl to access cluster, you need to get the kubeconfig file and set the environment.

Export this config in variable called KUBECONFIG so that kubectl can utilise this to send commands to cluster:

```bash
k0sctl kubconfig > kubeconfig
```

Also may be if you prefer you can update ~/.zshrc to have this varible placed each time shell starts.

```bash
export KUBECONFIG=$PWD/kubeconfig
```

## Get the nodes in the cluster:

Running the below command will exclusively display worker nodes. This is by design in K0s, as it enforces strict
isolation between control plane components (Controllers) and worker agents (Workers).

```bash
$ kubectl get nodes
NAME                    STATUS   ROLES    AGE   VERSION
worker-01.example.com   Ready    <none>   10m   v1.30.2+k0s
```

<hr/>

## Test the deployment (Optional)

You can test nginx deployment,

Save the YAML content to a file and then use the `kubectl apply` command.

Here are the steps:

- **Save the YAML content to a file** (e.g., `nginx-deployment.yaml`):
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
              image: nginx:1.27 # Use a specific version instead of latest
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

- **Apply the YAML file to your Kubernetes cluster**:
    ```bash
    kubectl apply -f nginx-deployment.yaml
    ```

These commands will create both the Service and Deployment resources in your Kubernetes cluster.

You can access now the nginx from your browser:
`worker-01.example.com:30000/`