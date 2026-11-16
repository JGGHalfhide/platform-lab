# platform-lab

Airgapped, STIG-hardened Kubernetes platform on personal lab hardware.
Built connected on a build cluster, packaged with Zarf, deployed with no
internet to a second cluster. 8-week build, about 7-10 hours per week.

## Hardware
- Build host: GMKtec K8 Plus (Ryzen 7 8845HS, 32GB RAM), Arch Linux,
  libvirt/QEMU/KVM at qemu:///system. Hosts the build cluster VMs.
- Disconnected target: old iMac (8GB RAM), Rocky Linux 9 (decided 11/14; was Fedora).
  Single-node RKE2, small workloads only. Same base/hardening/rke2 roles and STIG scan as the build cluster.
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
- make image IMAGE=<ref>: SBOM, scan gate, push to registry.platform-lab.internal

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
Lab SSH key is ~/.ssh/platform-lab_ecdsa (FIPS rejects ed25519).
Done (11/14): from-scratch rebuild 7m20s, same results; Week 2 tagged v0.2.
Week 3 (GitOps and registry):
Done (11/14): Argo CD v3.6.1 (`make argocd`, run by `make up`), app-of-apps root
(gitops/root.yaml -> gitops/apps/), Argo CD self-managed; restricted PSS, no exemption.
Done (11/15): local-path-provisioner (default StorageClass, privileged PSS exception
for its helper pods) and Zot v2.1.23 via Argo CD (anonymous read, admin push with
htpasswd from Vault via `registry_auth` role; NodePort 30500, Traefik ingress
registry.platform-lab.internal).
Done (11/15): push/pull test (crane push as admin, restricted pod pulls via 127.0.0.1:30500).
Done (11/15): rebuild 8m12s; kube-bench 80 pass / 1 fail (5.1.3 Argo CD wildcard
RBAC, documented in docs/kube-bench.md; 5.1.5/5.1.6 fixed with projected tokens);
STIG 398/29 (new exception no_files_unowned_by_user); Zot runs as UID 65532.
Week 3 tagged v0.3.
Week 4 (supply chain):
Done (11/15): TLS push path: lab CA (`scripts/lab-pki.sh`, keys in Vault, pki/lab-ca.crt),
registry-tls Secret via `registry_auth`; node pinned to 192.168.122.10 (fixed MAC +
DHCP reservation), /etc/hosts entry from host-bootstrap. Rebuild 8m00s.
Done (11/15): `make image IMAGE=<ref>`: pull (all platforms), Syft SBOMs, Trivy scan +
gate (fixable CRITICAL), push over TLS with upstream digest preserved; build/ gitignored.
Done (11/15): cosign key pair (`scripts/cosign-keygen.sh`): private key
~/.config/platform-lab/cosign.key, password in Vault (vault_cosign_password),
public key pki/cosign.pub. No Rekor: sign with --use-signing-config=false --tlog-upload=false.
Done (11/15): `make image` signs the index digest and attaches the SPDX SBOM as a cosign
attestation (tag-based .sig/.att via --new-bundle-format=false; skipped when already valid).
Done (11/15): Kyverno v1.19.2 (chart 3.9.2) via Argo CD, restricted PSS, no token
automount; CRD migration hook disabled (it broke kube-bench 5.1.6). kube-bench 80/1.
Done (11/15): ImageValidatingPolicy verify-platform-images (digest + signature for
127.0.0.1:30500/* images, verified via zot.zot.svc:5000 through a custom image extractor);
signed admitted, unsigned rejected (docs/supply-chain.md). SBOM attestation not checked at
admission (Kyverno bug #17109; tracked in ROADMAP open questions).
Done (11/15): rebuild 8m09s (site.yml now waits for SSH: stale lease with the fixed MAC);
apps healthy, changed=0, admission test passes, kube-bench 80/1, STIG 398/29. Week 4 tagged v0.4.
After a rebuild the registry is empty: republish images with `make image`.
Week 5 (policy set):
Done (11/16): seven Kyverno ValidatingPolicies in gitops/policies/ (Audit), `make policy-test`
(76 kyverno test cases, generated by tests/policies/generate.py). Audit findings fixed
(Argo CD/local-path resources, labels) or exempted (PolicyExceptions only in kyverno ns:
platform-bootstrap-images via allowedValues, local-path-helper-pods). Reports: 0 failures.
Done (11/16): policies switched to Enforce (Deny); non-compliant pod rejected with readable
messages, platform pods and PVC helper pods still admitted (docs/scans/week5-enforce-test.txt).
Next: docs/policy-map.md, rebuild acceptance, tag v0.5.
GitHub Actions item deferred to Week 8. Post 2 is the user's to write.
Reminders for Week 8 (in ROADMAP.md): circle back to the deferred Week 4 GitHub Actions
workflow; remind the user about docs/stack.md (full tech stack spec with each tool's use
and rationale, end-to-end workflow breakdown, Mermaid diagram).
Post 1 (hardening results) is the user's to write.
See ROADMAP.md for the checklist.
Note: in Claude Code sessions run ansible with `</dev/null` (non-blocking IO error otherwise).
