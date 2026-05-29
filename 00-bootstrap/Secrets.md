# 1Password Secrets Catalog

This catalog lists the 1Password secret references currently used by bootstrap and post-install provisioning.

## Vault

- Vault name: Homelab

## Required Secrets

| Reference | Used by | Purpose |
|---|---|---|
| `op://Homelab/ProxmoxRoot/password` | 00-bootstrap/answer.template.toml | Proxmox root password for installer answer file |
| `op://Homelab/ProxmoxAdmin/password` | 00-bootstrap/provision-users.template.env | Plaintext admin password. Hashed during provision-users stage before Linux account update |
| `op://Homelab/ProxmoxAdmin/public key` | 00-bootstrap/provision-users.template.env | Admin SSH public key installed for Linux admin user |
