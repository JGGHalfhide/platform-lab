# platform-lab

Airgapped, STIG-hardened Kubernetes platform built on personal lab hardware.
Status: Week 2 (OS hardening) complete, tagged v0.2: DISA STIG scan 38.6% -> 93.4% (see docs/hardening.md). Next: Week 3.

## Rebuild time

Measured from scratch on the build host (base image already in the pool):

| Date       | `make down` | `make up` (to Ready node) |
|------------|-------------|---------------------------|
| 2026-11-14 | 2s          | 4m34s                     |
| 2026-11-14 | 2s          | 7m20s (with STIG hardening, FIPS, AIDE; 2 reboots) |

## Secrets and keys (not in the repo)

| File | What | Notes |
|------|------|-------|
| `~/.config/platform-lab/vault-pass` | Ansible Vault key | Decrypts `ansible/group_vars/all/vault.yml` (sudo and GRUB passwords). Back it up in a password manager: without it the playbook cannot run. |
| `~/.ssh/platform-lab_ecdsa` | Lab SSH key (ECDSA P-384) | FIPS mode rejects ed25519 keys. Installed by cloud-init and the base role. |

View the secrets with `cd ansible && ansible-vault view group_vars/all/vault.yml`.
