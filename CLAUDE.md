# platform-lab

Airgapped, STIG-hardened Kubernetes platform on personal lab hardware.
Built connected on a build cluster, packaged with Zarf, deployed with no
internet to a second cluster. 8-week build, about 7-10 hours per week.

## Hardware
- Build host: GMKtec K8 Plus (Ryzen 7 8845HS, 32GB RAM), Arch Linux,
  libvirt/QEMU/KVM at qemu:///system. Hosts the build cluster VMs.
- Disconnected target: old iMac (8GB RAM), Fedora. Single-node RKE2, small workloads only.
- Optional arm64 node: Raspberry Pi 4, Fedora.
- Dev machine: MacBook Air M2.

## Stack
- Provisioning: Terraform (dmacvicar/libvirt provider), Ansible
- Guest OS: Rocky Linux 9 GenericCloud image (cloud-init)
- Kubernetes: RKE2 with the CIS profile, SELinux enforcing
- GitOps: Argo CD (app-of-apps)
- Registry: Harbor or Zot
- Supply chain: Syft (SBOM), Trivy, cosign
- Policy: Kyverno (Pod Security Standards, K8s STIG mappings)
- Compliance scanning: OpenSCAP, kube-bench
- Airgap packaging: Zarf
- Observability and recovery: Prometheus, Grafana, Loki, Velero, etcd snapshots

## Repo layout
    terraform/   libvirt VMs for each cluster
    ansible/     OS hardening and RKE2 install roles (roles/ holds one role per concern)
    gitops/      Argo CD apps and Kyverno policies
    zarf/        airgap packages
    docs/        ADRs, diagrams, scan reports
    Makefile     up / down / verify

## Commands
- make up: terraform apply, then run the Ansible playbook
- make down: terraform destroy
- make verify: kubectl get nodes against ./kubeconfig

## Conventions
- Everything is reproducible from the repo: no manual steps on VMs.
- Ansible roles are idempotent; a second run reports zero changes.
- Terraform: variables typed with descriptions; outputs for VM IPs.
- Run terraform fmt, terraform validate, and ansible-lint before committing.
- Commit messages use conventional commits (feat:, fix:, docs:, chore:).
- Tag the repo at the end of each week (v0.1, v0.2, ...).
- ADRs live in docs/adr/NNNN-title.md and state the decision and its context only.
- Secrets, kubeconfigs, and state files are never committed.
- Ask before running terraform destroy or any command that deletes VMs or volumes.

## Ground rules
- Built from scratch on personal hardware.
- No configs, naming, hostnames, or architecture from any employer system appear
  in code, docs, or posts.
- Sample applications are generic (a small web app and a database).

## Current status
Week 1 (foundation): repo skeleton, Terraform/libvirt VM, base Ansible role,
RKE2 role with CIS profile, kube-bench baseline saved to docs/.
Done when `make up` builds a Ready single-node cluster from scratch.
