# platform-lab

An airgapped, DISA STIG-hardened Kubernetes platform, built from scratch on
personal lab hardware.

The platform is built and tested on a connected build cluster, packaged with
[Zarf](https://zarf.dev), and deployed to a second cluster that has no
internet access. Everything is reproducible from this repo: VMs come from
Terraform, every OS and cluster setting comes from Ansible, and nothing is
configured by hand.

## Architecture

```
  Build host (Arch Linux, libvirt/KVM)              Disconnected target
 ┌────────────────────────────────────────┐        ┌──────────────────────┐
 │  Terraform ──► Rocky Linux 9 VM        │        │  RKE2 single node    │
 │  Ansible   ──► base, STIG hardening,   │  Zarf  │  (no internet)       │
 │                RKE2 (CIS profile)      │ ─────► │                      │
 │                                        │package │  same hardening      │
 │  Build cluster: RKE2, Argo CD, Kyverno,│        │  and policy          │
 │  registry, observability               │        │                      │
 └────────────────────────────────────────┘        └──────────────────────┘
```

| Layer | Tooling |
|---|---|
| Provisioning | Terraform ([dmacvicar/libvirt](https://github.com/dmacvicar/terraform-provider-libvirt)), cloud-init, Ansible |
| OS | Rocky Linux 9, SELinux enforcing, FIPS mode, firewalld on |
| Kubernetes | RKE2 with the CIS profile |
| Compliance | OpenSCAP (RHEL 9 STIG profile), kube-bench (RKE2 CIS benchmark) |
| GitOps and policy | Argo CD, Kyverno |
| Supply chain | Syft (SBOM), Trivy, cosign, Harbor or Zot |
| Airgap | Zarf |
| Observability and recovery | Prometheus, Grafana, Loki, Velero, etcd snapshots |

## Results so far

| Measure | Result |
|---|---|
| DISA STIG scan (OpenSCAP, RHEL 9 STIG profile) | 38.6% → **93.4%** pass (164 → 399 rules); high-severity fails 11 → 1 |
| Remaining STIG fails | 28, every one a documented exception with a reason |
| kube-bench (RKE2 CIS 1.9) | 81 pass, **0 fail** before and after OS hardening |
| Rebuild from nothing (`make down && make up`) | **7m20s** to a Ready, hardened node |
| Idempotency | Second Ansible run reports `changed=0` |

Details: [docs/hardening.md](docs/hardening.md). Scan reports are in
[docs/scans/](docs/scans/) (OpenSCAP reports are gzipped HTML and XCCDF XML).

## Quickstart

### Prerequisites

On the build host:

- libvirt with QEMU/KVM, using `qemu:///system`
- Terraform, Ansible (ansible-core 2.16+) and ansible-lint, kubectl
- An ECDSA P-384 SSH key at `~/.ssh/platform-lab_ecdsa` (FIPS mode rejects
  ed25519):

  ```
  ssh-keygen -t ecdsa -b 384 -f ~/.ssh/platform-lab_ecdsa
  ```

- An Ansible Vault key at `~/.config/platform-lab/vault-pass`. It decrypts
  `ansible/group_vars/all/vault.yml`, which holds the admin sudo password
  and the GRUB password. A fresh clone needs its own vault with the same
  variable names (`vault_admin_password`, `vault_admin_password_hash`,
  `vault_grub_password`, `vault_grub_password_pbkdf2`). Keep the key backed
  up: without it the playbook cannot run.

### Build, check, tear down

```
make up          # host setup, VM, then the Ansible playbook (base, hardening, OpenSCAP, RKE2)
make verify      # kubectl get nodes against ./kubeconfig

make stig-scan NAME=my-scan        # OpenSCAP STIG scan -> docs/scans/my-scan.*
make bench OUT=docs/scans/kb.txt   # kube-bench Job, report saved, Job removed

make down        # destroys the VM (keeps the base image)
```

`make up` is safe to rerun: the playbook is idempotent. Secrets,
kubeconfigs and Terraform state never go into the repo.

## Repository layout

```
terraform/   libvirt VMs and cloud-init
ansible/     playbooks and roles (one role per concern)
  roles/base        packages, time sync, firewalld, NetworkManager, SELinux
  roles/hardening   DISA STIG hardening, with documented exceptions
  roles/openscap    scanner install and STIG scan tasks
  roles/rke2        RKE2 with the CIS profile
gitops/      Argo CD applications and Kyverno policies
zarf/        airgap packages
scripts/     host bootstrap and kube-bench runner
docs/        hardening write-up, scan reports, ADRs
Makefile     up / down / verify / bench / stig-scan
```

## Hardware

- Build host: mini PC, Ryzen 7 8845HS, 32 GB RAM, Arch Linux
- Disconnected target: older iMac, 8 GB RAM
