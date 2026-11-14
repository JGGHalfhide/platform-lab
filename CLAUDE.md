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
- make bench OUT=docs/scans/<name>.txt: kube-bench Job, report saved, Job removed
- make stig-scan NAME=<name>: OpenSCAP STIG scan, reports to docs/scans/<name>.*

## Conventions
- Everything is reproducible from the repo: no manual steps on VMs.
- Ansible roles are idempotent; a second run reports zero changes.
- Terraform: variables typed with descriptions; outputs for VM IPs.
- Run terraform fmt, terraform validate, and ansible-lint before committing.
- Commit messages use conventional commits (feat:, fix:, docs:, chore:).
- No AI attribution in commits or PRs (no Co-Authored-By or "Generated with" lines).
- Tag the repo at the end of each week (v0.1, v0.2, ...).
- ADRs live in docs/adr/NNNN-title.md and state the decision and its context only.
- Secrets, kubeconfigs, and state files are never committed. Secrets go in
  ansible/group_vars/all/vault.yml (Ansible Vault; key at ~/.config/platform-lab/vault-pass).
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

Done (10/13): host bootstrap (`make host`: default pool + pinned Rocky 9.8
image) and Terraform for one VM (`build-node-01`, DHCP address from `terraform output vm_ip`).
Done (10/13): Ansible inventory (`make inventory`) and base role (updates,
chrony, firewalld kept on with RKE2 ports and pod/service CIDRs trusted,
NetworkManager CNI exclusions, SELinux enforcing); idempotent.
Done (10/13): RKE2 role (v1.36.5+rke2r1, CIS profile, SELinux, etcd user,
CIS sysctls, kubeconfig at ./kubeconfig); node Ready; pod networking verified
with firewalld on.
Done (11/14): kube-bench baseline (`make bench`, RKE2 CIS 1.9): 81 pass, 0 fail,
42 warn (manual checks); docs/scans/week1-kube-bench.txt.
Done (11/14): Week 1 complete, tagged v0.1. Rebuild from scratch: 4m34s to a Ready
node; RKE2 pinned with dnf versionlock (the package update had moved it to 1.36.6).
Week 2 (OS hardening):
Done (11/14): `openscap` role and `make stig-scan NAME=...`; baseline STIG scan
164 pass / 261 fail (38.6%), docs/scans/week2-baseline.{html,xml}.gz.
Done (11/14): `hardening` role (Vault secrets, FIPS:STIG, SSH, PAM/authselect,
audit, kernel, GRUB, AIDE; 28 exceptions in hardening_exceptions). Rescan:
399 pass / 28 fail (93.4%); kube-bench still 0 fail; docs/hardening.md.
Lab SSH key is ~/.ssh/platform-lab_ecdsa (FIPS rejects ed25519). The next
`make up` replaces the VM (Terraform key default changed).
Next: full `make down && make up` rebuild with hardening (ask first), then tag v0.2.
See ROADMAP.md for the checklist.
Note: in Claude Code sessions run ansible with `</dev/null` (non-blocking IO error otherwise).
