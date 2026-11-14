# platform-lab

Airgapped, STIG-hardened Kubernetes platform built on personal lab hardware.
Status: Week 1 (foundation) complete, tagged v0.1. Next: Week 2 (OS hardening).

## Rebuild time

Measured from scratch on the build host (base image already in the pool):

| Date       | `make down` | `make up` (to Ready node) |
|------------|-------------|---------------------------|
| 2026-11-14 | 2s          | 4m34s                     |

## Secrets and keys (not in the repo)

| File | What | Notes |
|------|------|-------|
| `~/.config/platform-lab/vault-pass` | Ansible Vault key | Decrypts `ansible/group_vars/all/vault.yml` (sudo and GRUB passwords). Back it up in a password manager: without it the playbook cannot run. |
| `~/.ssh/platform-lab_ecdsa` | Lab SSH key (ECDSA P-384) | FIPS mode rejects ed25519 keys. Installed by cloud-init and the base role. |

View the secrets with `cd ansible && ansible-vault view group_vars/all/vault.yml`.
