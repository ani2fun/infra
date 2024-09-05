# Ansible Setup and Usage Guide

This guide provides instructions on setting up Ansible on macOS, creating and managing an Ansible Vault, and running a playbook with encrypted variables.

## Prerequisites

- macOS
- Homebrew installed (for installing Ansible)

## 1. Install Ansible on macOS

To install Ansible on macOS, use Homebrew:

```bash
brew install ansible
```

## 2. Setup Ansible Vault for Secure Variable Storage

### 2.1 Create a Directory for Secrets

Create a directory to store your Ansible Vault password file:

```bash
mkdir -p $HOME/secrets
```

### 2.2 Create the Vault Password File

**Create an Ansible Vault password file and generate a random secure password and save it on your local laptop in file let's call it `ansible-vault.pass` :**

```bash
touch $HOME/secrets/ansible-vault.pass
openssl rand -base64 2048 > $HOME/secrets/ansible-vault.pass
```

### 2.3 Export Vault Password File as an Environment Variable

**To make the Vault password file available to Ansible, export it as an environment variable:**

```bash
export ANSIBLE_VAULT_PASSWORD_FILE=$HOME/secrets/ansible-vault.pass
```

### 2.4 Create and Manage the Ansible Vault File

Create a new Ansible Vault file to store sensitive variables:

```bash
ansible-vault create group_vars/vault.yml
```

You can view the contents of the Vault file using:

```bash
ansible-vault view group_vars/vault.yml
```

To edit the Vault file, use:

```bash
ansible-vault edit group_vars/vault.yml
```

## 3. Secure Password Generation and Storage

### 3.1 Generate a Secure Password

- **To generate a SHA-512 hashed passwords using SHA-512 encryption:**

```bash
openssl passwd -6 "super_secret"
```

- **Replace `"super_secret"` with your desired password.**

### 3.2 Store the Passwords in the Ansible Vault

- **Edit the `vault.yml` file to store the generated passwords:**

```bash
ansible-vault edit group_vars/vault.yml
```

- **sample content of `vault.yml`:**

```yaml
---
admin_password: <SHA-512 generated password goes here>
ansible_password: <SHA-512 generated password goes here>
db_password: <SHA-512 generated password goes here>
...
```

- **Replace the placeholders with the actual SHA-512 hashed passwords generated in the previous step.**

## 4. Running Ansible Playbook

**NOTE:** Inventory file is specified in `ansible.cfg`.

To run your Ansible playbook using the inventory and playbook files:

Change the current directory to the Ansible directory:

```bash
cd ansible-plays
```

Run the playbook:

```bash
ansible-playbook playbook.yml
```

### 4.1 Run Specific Parts of the Playbook

You can provide specific tags to run only the sections you need. 

**Check the extra vars:**


**Set Hostnames:**
```bash
ansible-playbook playbook.yml --tags "setup_hostname"
```

For example, to run only the WireGuard configuration:

```bash
ansible-playbook playbook.yml --tags "test_connectivity"
```

Or, if you need to run multiple sections:

```bash
ansible-playbook playbook.yml --tags "install_packages,generate_wireguard_keys"
```

## Conclusion

You have now successfully set up Ansible on your macOS machine, created and managed an Ansible Vault for secure storage of sensitive variables, and run a playbook with encrypted variables. Make sure to keep your Vault password file secure to protect your sensitive information.
