# platform-lab Roadmap

Airgapped, STIG-hardened Kubernetes platform. 8 weeks, about 7-10 hours per week.
Status is tracked with the checkboxes below. Claude Code reads this file at the start of each session.

## How to use this file (for Claude Code)

- Read CLAUDE.md and this file at the start of every session.
- Work on the first unchecked item of the earliest incomplete week unless told otherwise.
- Propose changes, show plans (`terraform plan`, `--check`, `--dry-run`) before applying, and ask before anything destructive.
- When a task is done: check its box here, update "Current status" in CLAUDE.md, and commit.
- At the end of a week: confirm every acceptance criterion, tag the repo (`vN.N`), and write down measured results in `docs/`.

## Session templates

Start of session:

```
Read CLAUDE.md and ROADMAP.md. Summarize where we are, then continue with the next unchecked item.
```

End of session:

```
Update ROADMAP.md checkboxes and the "Current status" section in CLAUDE.md. Run terraform fmt/validate and ansible-lint. Show me git status, then commit with a conventional commit message.
```

---

## Week 1 — Foundation

Goal: `make up` builds a Ready, CIS-profile RKE2 cluster from nothing.

- [x] Rocky Linux 9 GenericCloud image in the libvirt pool
  - `scripts/host-bootstrap.sh` (`make host`, run by `make up`): creates the missing `default` pool, uploads the pinned `Rocky-9-GenericCloud-Base-9.8-20260525.0` image after a SHA256 check. Idempotent.
- [x] Terraform: one VM (4 vCPU, 8GB RAM, 40GB disk), COW volume, cloud-init with SSH key, IP output
  - dmacvicar/libvirt `~> 0.9.9`. VM `build-node-01`, user `rocky`, key-only SSH. Outputs `vm_ip`, `ssh_command`.
  - Gotcha: the 0.9 provider starts q35 guests with `acpi=off` unless `features = { acpi = true, apic = {} }` is set; without it the guest never gets a DHCP lease.
- [x] Prereq: `ansible-core` and `ansible-lint` installed on the build host (pacman `ansible` 14.5.0 / ansible-core 2.21.5, `ansible-lint` 26.10.0)
- [x] Ansible: inventory generated from Terraform output (generated file is gitignored); base role (updates, chrony, firewall, NetworkManager, SELinux enforcing)
  - `make inventory` writes `ansible/inventory.ini` from `vm_ip`. Second run reports `changed=0`; ansible-lint passes at the `production` profile.
  - Firewall: decided option (a), firewalld on. RKE2 ports open in `public`; 10.42.0.0/16 and 10.43.0.0/16 in `trusted`. Pod-to-pod and DNS must be verified once RKE2 is up (RKE2 role item).
  - NetworkManager: drop `/etc/NetworkManager/conf.d/rke2-canal.conf` marking `flannel*`, `cali*`, `tunl*`, `vxlan.calico`, `vxlan-v6.calico`, `wireguard.cali`, `wg-v6.cali` unmanaged (RKE2 known issue).
  - `PermitRootLogin` is `without-password` from the image; left as-is so the Week 2 baseline scan captures it, then fixed in the hardening role.
- [x] Ansible: RKE2 role (rke2-selinux, `profile: cis`, `etcd` system user, CIS sysctl file, kubeconfig fetched to repo root)
  - RKE2 v1.36.5+rke2r1 (stable) from the signed rpm.rancher.io repos, version pinned; signing key pinned by fingerprint. `rke2` runs as `container_runtime_t`; etcd runs as `etcd`, data dir `etcd:etcd 0700`. Idempotent (`changed=0`).
  - Firewalld option (a) verified 10/13: pod-to-pod, Service by name, cluster and external DNS, pod egress, pod-to-API, node-to-pod, NodePort from the build host all pass; listening but unopened ports (8081, 9091, 111) are rejected from outside.
  - `kubectl` 1.37.1 installed on the build host (pacman); `make verify` shows the node Ready over TLS via `tls-san`.
- [x] kube-bench baseline saved to `docs/scans/week1-kube-bench.txt`
  - `make bench OUT=...` runs kube-bench v0.16.0 (pinned by digest) as a Job with `--benchmark rke2-cis-1.9` (newest RKE2 benchmark in kube-bench; the cluster is 1.36), then deletes it.
  - Baseline 11/14: 81 PASS, 0 FAIL, 42 WARN (all Manual checks), 7 INFO.
  - The scanner must not trip its own section 5 checks: an earlier run showed 3 FAILs (5.1.3, 5.1.5, 5.1.6) caused by its wildcard ClusterRole and automounted token. Fixed with scoped read-only RBAC and an explicitly projected token.
- [x] Makefile: `up`, `down`, `verify`; full rebuild timed and recorded in README
  - 11/14: `make down` 2s, `make up` 4m34s to a Ready node; second playbook run `changed=0`.
  - Found by the rebuild: the base role's package update moved RKE2 from the pinned 1.36.5 to 1.36.6 on the second run (the repo serves every 1.36 patch). Fixed with a dnf versionlock on `rke2-server`/`rke2-common`, written before install so bumping `rke2_version` still upgrades.
  - The VM address is DHCP-assigned and changes per rebuild; inventory, `tls-san` and the kubeconfig follow the Terraform output.
  - `up` already uses plain `terraform init` (provider versions come from `.terraform.lock.hcl`).
- [x] Tag `v0.1`

Acceptance: `make down && make up` produces `kubectl get nodes` Ready with no manual steps.

Claude Code prompt:

```
Continue Week 1 in ROADMAP.md. Write the Ansible base role and the RKE2 role (CIS profile, SELinux, etcd user, sysctl file). Generate the inventory from the Terraform output. Run with --check first and show me the results before applying. Then run kube-bench with the RKE2 benchmark and save the output to docs/scans/.
```

## Week 2 — OS hardening and compliance baseline

Goal: measurable before/after STIG results on the node OS.

- [x] Install `openscap-scanner` and `scap-security-guide` on the VM via Ansible
  - `openscap` role in `site.yml` (openscap-scanner 1.3.14, scap-security-guide 0.1.82). Datastream `ssg-rl9-ds.xml`, profile `xccdf_org.ssgproject.content_profile_stig` (Rocky's port of the RHEL 9 DISA STIG; DISA publishes no STIG for Rocky itself).
- [x] Note for the hardening role: `rpcbind` is listening on 111 (blocked by firewalld, but the STIG wants it removed or disabled)
  - Removed with `nfs-utils` (its only dependent) in the hardening role.
- [x] Baseline OpenSCAP scan against the STIG profile for the installed datastream (list `/usr/share/xml/scap/ssg/content/` to find it); HTML and XML reports to `docs/scans/week2-baseline.*`
  - `make stig-scan NAME=<name>` runs `ansible/stig-scan.yml` (about 30s) and fetches the HTML report and XCCDF results. Only `.gz` copies are committed; raw files are ~27 MB per scan and gitignored.
  - Baseline 11/14: 164 pass, 261 fail (38.6% of 425 scored rules); 10 notchecked, 42 notapplicable. Fails by severity: 11 high, 227 medium, 20 low, 3 unknown.
- [x] Ansible hardening role covering the failed rules (generate remediation with `oscap xccdf generate fix` as a starting point, then convert to idempotent tasks)
  - `hardening` role, one task file per area; exceptions in `hardening_exceptions` (28, each with a reason). Secrets in Ansible Vault. FIPS mode on (lab key is now ECDSA P-384: FIPS rejects ed25519). Idempotent (`changed=0`).
- [x] Re-scan; reports to `docs/scans/week2-hardened.*`
  - 11/14: 399 pass, 28 fail (93.4%), up from 164/261 (38.6%). High-severity fails 11 -> 1. Every remaining fail is a documented exception.
- [x] `docs/hardening.md`: table of rule IDs, status, and any documented exceptions
- [x] Confirm RKE2 still starts and passes kube-bench after hardening
  - kube-bench 81 pass / 0 fail (`docs/scans/week2-kube-bench.txt`); pod-to-pod, Service, DNS, egress and NodePort tests pass.
- [x] Full `make down && make up` rebuild with hardening (acceptance; the Terraform key change replaces the VM anyway)
  - 11/14: `make up` 7m20s to a Ready hardened node; second run `changed=0`; scan 399/28 and kube-bench 0 fail, same as the incrementally hardened VM. The first attempt found an AIDE config bug that only shows on a fresh image (fixed).
- [x] Tag `v0.2`
- [ ] Publish Post 1 (hardening results)

Acceptance: second scan shows a measurable pass-rate increase; `make up` still works end to end.

Claude Code prompt:

```
Week 2 in ROADMAP.md. Add OpenSCAP scanning to the Ansible roles, run the baseline STIG scan against the Rocky VM, and save the HTML/XML reports to docs/scans/. Then build an idempotent hardening role for the failed rules, with a variable-driven exceptions list for rules that break RKE2. Re-scan and produce docs/hardening.md with before/after pass counts.
```

## Week 3 — GitOps and registry

Goal: cluster state is driven from `gitops/`.

- [x] Install Argo CD (Helm or manifests) via an Ansible task or Makefile target, once
  - 11/14: Argo CD v3.6.1 from the pinned upstream `install.yaml` via `gitops/argocd/kustomization.yaml`; `make argocd` (server-side apply; CRDs are too large for client-side), run by `make up`. No Helm on the host.
  - Passes the CIS profile's cluster-wide `restricted` Pod Security level with no exemption (server dry run showed no warnings).
- [x] App-of-apps root application pointing at `gitops/apps/`
  - `gitops/root.yaml` (automated, prune, selfHeal), one Application per file in `gitops/apps/`. Argo CD reads the public GitHub repo, so changes must be pushed before they sync.
- [x] Argo CD manages itself from Git
  - `gitops/apps/argocd.yaml` points at the same kustomization used for bootstrap (ServerSideApply, selfHeal, no prune). Self-heal check: a deleted NetworkPolicy was restored in 2s.
- [x] In-cluster registry (Zot by default; Harbor optional) deployed via Argo CD, with persistent storage (local-path-provisioner)
  - local-path-provisioner v0.0.37 (`gitops/local-path-storage`, default StorageClass). Namespace enforces `privileged` (helper pods mount hostPath), warn/audit stay `restricted`; the provisioner itself runs restricted. Helper image pinned (`busybox:1.37.0@sha256:...`; upstream is untagged). Volume dirs `1777` (sticky, for STIG); `/opt/local-path-provisioner` created by the rke2 role (`0700`, `container_file_t` from rke2-selinux). Tested: non-root pod writes to a PVC; deleting the PVC removes the directory.
  - Zot v2.1.23, Helm chart 0.1.134 (`gitops/apps/zot.yaml`), StatefulSet with a 10Gi local-path PVC, restricted securityContext. Anonymous read; push only as `admin` (htpasswd). The htpasswd Secret is built from Ansible Vault by the `registry_auth` role (hash stored in Vault so the role stays idempotent). Tested: anonymous push 401, wrong password 401, admin 202.
  - NodePort 30500 for node pulls via `127.0.0.1:30500` (Zarf's pattern); ingress for pushes and the UI.
- [x] Ingress using the controller bundled with the installed RKE2 version (v1.36 ships Traefik, `rke2-traefik` in `kube-system`)
  - `registry.platform-lab.internal` on Traefik (host ports 80/443, Traefik's default self-signed cert for now). Traefik never publishes an Ingress address, so `argocd-cm` treats Ingresses as Healthy once they exist.
- [x] Push a test image to the registry and pull it from a pod
  - 11/15: `crane copy` of `busybox:1.37.0` and `alpine:3.22` (pinned digests) into Zot as `admin`; digests unchanged; anonymous push rejected (UNAUTHORIZED). A restricted, non-root pod pulled `127.0.0.1:30500/library/alpine:3.22@sha256:...` in 178ms; Zot's log shows containerd (v2.3.4-k3s1) fetching both manifests and both blobs over plain HTTP to localhost, so no `registries.yaml` change is needed.
  - The push went over the NodePort (HTTP) because the build host cannot resolve `registry.platform-lab.internal`. Week 4's push script should use the TLS ingress: needs name resolution on the build host and a trusted CA instead of Traefik's self-signed default.
- [x] Full `make down && make up` rebuild (acceptance check before tagging)
  - 11/15: `make up` 8m12s to a Ready node with all four Argo CD apps Synced/Healthy; second Ansible run `changed=0`; push/pull retested.
  - The rebuild's scans found regressions from the new workloads. kube-bench 3 FAIL: 5.1.5 and 5.1.6 were fixed (no token automount outside kube-system; projected tokens for API clients), and 5.1.3 (Argo CD wildcard ClusterRoles) is a documented exception, giving 80 pass / 1 fail. STIG 398/29: new `no_files_unowned_by_user` (container UIDs) added as exception 29. Details in `docs/kube-bench.md` and `docs/hardening.md`.
  - Zot moved from UID 1000 (the node's `rocky` user) to 65532; its PVC was recreated.
- [x] Tag `v0.3`

Acceptance: deleting an app's resources causes Argo CD to restore them; a commit to `gitops/` changes the cluster.

Claude Code prompt:

```
Week 3 in ROADMAP.md. Install Argo CD, create the app-of-apps layout under gitops/, and have Argo CD manage itself. Deploy an in-cluster OCI registry through Argo CD with persistent storage. Show me the manifests before committing, and verify by pushing and pulling a test image.
```

## Week 4 — Supply chain

Goal: every platform image is scanned, has an SBOM, and is signed; unsigned images are rejected.

- [x] Script/Makefile target: pull image, generate SBOM (Syft), scan (Trivy), push to in-cluster registry
  - `make image IMAGE=<ref>` (`scripts/publish-image.sh`): resolves to a digest, pulls the whole index (all platforms) as an OCI layout, Syft SPDX + CycloneDX SBOMs and a Trivy JSON/table report for `linux/amd64`, then the gate: fail on any CRITICAL with a fix available (`GATE_SEVERITY`; exceptions in `.trivyignore`). Pushes to `registry.platform-lab.internal/<repo>:<tag>` and checks the pushed digest equals upstream. Outputs in `build/images/` (gitignored).
  - 11/15: `alpine:3.22` and `busybox:1.37.0` pass (0 fixable CRITICAL) and push with upstream digests; `nginx:1.25.0` is blocked (7 fixable CRITICAL). A restricted pod pulled the pushed alpine digest via `127.0.0.1:30500`.
  - The digest check caught a bug in the first version: `crane push --index` wrapped the upstream index in a new one (different digest). Plain `crane push` of the single-entry layout keeps it.
  - Week 3 open item closed (TLS push path): lab CA (`scripts/lab-pki.sh`, ECDSA P-384, keys in Vault, CA cert in `pki/lab-ca.crt`); `registry_auth` creates the `registry-tls` Secret for the Zot ingress. Terraform pins the node MAC and `host-bootstrap.sh` reserves 192.168.122.10 for it and adds the `/etc/hosts` entry (passwordless sudo, once). Scripts trust the CA via `SSL_CERT_FILE` and log in with a throwaway `DOCKER_CONFIG` (`scripts/lib.sh`); nothing is installed system-wide.
  - Rebuild 11/15: `make down` 1s, `make up` 8m00s, node at 192.168.122.10, all apps Synced/Healthy, second Ansible run `changed=0`.
- [x] cosign key pair generated locally (private key never committed; public key committed under `gitops/` or `docs/`)
  - 11/15: `scripts/cosign-keygen.sh` (cosign v3.1.3, ECDSA P-256). Private key at `~/.config/platform-lab/cosign.key` (0600, outside the repo; back it up with `vault-pass`); its random password in Vault as `vault_cosign_password`; public key committed at `pki/cosign.pub` next to the lab CA. Refuses to overwrite an existing key.
  - Round trip checked: sign-blob with the Vault password, verify with `pki/cosign.pub`; a modified file fails verification.
  - cosign v3 needs `--use-signing-config=false --tlog-upload=false` to sign without the public Rekor log (the airgap target can't reach it); verification then needs `--insecure-ignore-tlog`. The Kyverno policy must skip Rekor too (`rekor.ignoreTlog`).
- [x] Sign images and attach SBOM attestations with cosign
  - 11/15: last step of `make image` (`SIGN=0` skips): `cosign sign` on the index digest and `cosign attest --type spdxjson` with the Syft SPDX SBOM, then `verify` and `verify-attestation` against `pki/cosign.pub`. No Rekor (`--use-signing-config=false --tlog-upload=false`; verify with `--insecure-ignore-tlog`).
  - Storage format: cosign v3 defaults to an OCI 1.1 referrer holding a Sigstore bundle. The script uses `--new-bundle-format=false` (sign and verify) for the tag-based `sha256-<digest>.sig` / `.att` layout, which Kyverno and Zarf have supported longest. To confirm with the Kyverno policy test and the Zarf transfer (Week 6).
  - Idempotent: skips signing when a valid signature and SBOM attestation already exist. Without that, every run added another `.att` layer (each SBOM has a fresh timestamp and ID); signatures did not stack.
  - Tested: `alpine:3.22` (17 packages) and `busybox:1.37.0` (2 packages) signed and attested; the attestation subject is the index digest; verification with a different public key fails ("invalid signature").
- [ ] Optional: GitHub Actions workflow for the connected build path (scan + SBOM on push)
  - Deferred 11/15 (user's call); must be revisited, not dropped. Tracked again in Week 8 ("Circle back").
- [ ] Kyverno installed via Argo CD
- [ ] Kyverno `verifyImages` policy using the cosign public key
- [ ] Test: signed image admitted, unsigned image rejected (record both outputs in `docs/`)
- [ ] Tag `v0.4`; publish Post 2 (supply chain)

Acceptance: an unsigned image deployment fails admission with a clear policy message.

Claude Code prompt:

```
Week 4 in ROADMAP.md. Build a script that pulls an image, runs Syft and Trivy, pushes it to the in-cluster registry, and signs it with cosign using a local key pair (add the private key path to .gitignore). Install Kyverno through Argo CD and add a verifyImages policy using the public key. Prove it with one signed and one unsigned deployment and save the outputs under docs/.
```

## Week 5 — Policy set

Goal: documented policies mapped to Pod Security Standards and Kubernetes STIG findings.

- [ ] Policies under `gitops/policies/`: Pod Security Standards restricted equivalents, no `latest` tags, required resource requests/limits, no privileged containers, no hostPath, required labels, trusted registries only
- [ ] `kyverno test` cases for each policy, run via a Makefile target
- [ ] All policies in Audit mode first; review PolicyReports; fix or exempt findings
- [ ] Switch to Enforce
- [ ] `docs/policy-map.md`: policy → control/finding mapping
- [ ] Tag `v0.5`

Acceptance: `make policy-test` passes; a deliberately non-compliant pod is rejected with a readable message.

Claude Code prompt:

```
Week 5 in ROADMAP.md. Write the Kyverno policy set under gitops/policies/ with kyverno test cases and a make policy-test target. Deploy in Audit mode through Argo CD, show me the PolicyReport results, then prepare the switch to Enforce. Create docs/policy-map.md mapping each policy to Pod Security Standards and the Kubernetes STIG.
```

## Week 6 — Airgap deployment

Goal: the same platform runs on the iMac cluster with no internet access.

- [ ] iMac: Rocky Linux 9 installed, base and hardening roles applied (adjust inventory), single-node RKE2 installed from airgap artifacts (RKE2 images tarball + install script staged over scp)
- [ ] Zarf installed on the build host (`zarf version` recorded)
- [ ] Zarf package definitions under `zarf/` for: platform components, Kyverno policies, sample app
- [ ] `zarf package create` on the connected host; transfer the package file to the iMac via scp/USB
- [ ] Disconnect: firewall rule blocking egress on the iMac; prove with a failing `curl`
- [ ] `zarf init` and `zarf package deploy` on the iMac with the network blocked
- [ ] Sample app runs; unsigned image still rejected by policy
- [ ] `docs/airgap-runbook.md`: exact step list
- [ ] Tag `v0.6`; publish Post 3 (airgap deploy)

Acceptance: platform and sample app come up on the iMac with egress blocked and no image pull errors.

Claude Code prompt:

```
Week 6 in ROADMAP.md. Prepare the iMac as a second RKE2 node set (single node) using our Ansible roles with a separate inventory group. Create Zarf package definitions under zarf/ for the platform, policies, and sample app. Document each step as you go in docs/airgap-runbook.md. Stop and ask me before blocking network egress on the iMac.
```

## Week 7 — Observability and recovery

Goal: metrics, logs, and a measured restore.

- [ ] kube-prometheus-stack and Loki (with Alloy; Promtail is end-of-life) deployed via Argo CD; included in the Zarf package
- [ ] Grafana dashboards for node, etcd, and policy reports committed as JSON under `gitops/`
- [ ] etcd snapshot: scheduled snapshots configured, manual `rke2 etcd-snapshot save`
- [ ] Restore drill: destroy state, `rke2 server --cluster-reset --cluster-reset-restore-path=<snapshot>`, verify; record elapsed time
- [ ] Velero with an in-cluster or local S3-compatible backend (MinIO); back up and restore the sample app namespace; record elapsed time
- [ ] `docs/recovery.md` with RTO measurements and procedures
- [ ] Tag `v0.7`

Acceptance: both restore drills complete with recorded times; dashboards show data on both clusters.

Claude Code prompt:

```
Week 7 in ROADMAP.md. Deploy kube-prometheus-stack and Loki through Argo CD, commit the Grafana dashboards as JSON, and add them to the Zarf package. Then walk me through the etcd snapshot restore drill and the Velero backup/restore drill, timing each, and write the procedures and measured times into docs/recovery.md. Ask before any step that destroys cluster state.
```

## Week 8 — Polish and publish

Goal: a repo a stranger can read and reproduce.

- [ ] README: overview, architecture diagram (Mermaid), quickstart, repo layout, measured results table
- [ ] ADRs in `docs/adr/` for the main platform choices (state the decision and context only)
- [ ] Demo recording (asciinema or screen capture) of `make up` through a policy rejection
- [ ] Secret scan with gitleaks over full history; fix anything found
- [ ] LICENSE (MIT or Apache-2.0)
- [ ] Confirm no employer-derived names, configs, or hostnames anywhere in the repo
- [ ] CI: terraform fmt/validate, ansible-lint, yamllint on pull requests
- [ ] Circle back: GitHub Actions supply-chain workflow deferred from Week 4 (scan + SBOM on push for the connected build path; can share the CI workflow above)
- [ ] Remind the user: full project spec in `docs/stack.md`, covering
  - Tech stack: every tool and component (host, provisioning, OS, Kubernetes, GitOps, registry, supply chain, policy, compliance, airgap, observability, recovery), with its version, what it does in this project, and why it was chosen over the alternatives (link the ADRs)
  - Workflow: the full end-to-end breakdown, from `make host` / `make up` through hardening, GitOps, image publishing (pull, SBOM, scan gate, push, sign, attest), policy admission, Zarf packaging and the airgapped deploy, to monitoring and restore
  - Diagram: a Mermaid source the user can render or redraw themselves
- [ ] Tag `v1.0`; publish Post 4 (architecture and lessons)

Acceptance: a fresh clone plus the README quickstart reproduces the build cluster.

Claude Code prompt:

```
Week 8 in ROADMAP.md. Write the README with a Mermaid architecture diagram and a results table pulled from docs/. Generate ADRs for the main platform choices. Run gitleaks over the full git history and report findings. Add a CI workflow for fmt/validate/lint, and circle back to the deferred Week 4 GitHub Actions supply-chain workflow. Write docs/stack.md (every tool, its use and why; the end-to-end workflow; a Mermaid diagram), and remind me about it. Then do a final pass to confirm nothing in the repo references any employer system.
```

---

## Open questions

Decide these before the week that depends on them.

- **Firewall vs. Canal (Week 1). Decided 10/13: (a).** Options: (a) keep firewalld on with RKE2 ports open and the CNI interfaces and pod/service CIDRs in the `trusted` zone, verified with pod-to-pod and DNS tests; or (b) disable firewalld per RKE2 docs and record a STIG exception with an ADR. (a) keeps the STIG control and is the more useful result if it holds up under testing.
- **iMac OS (Week 6). Decided 11/14: Rocky Linux 9.** Fedora has no STIG profile in scap-security-guide (CIS, OSPP, PCI-DSS and others only), and rke2-selinux packages target EL. Rocky 9 on the iMac lets the same base, hardening and RKE2 roles and the STIG scan apply to both clusters. Install from the Rocky 9 minimal/DVD ISO on bare metal (no cloud-init); the RKE2 airgap install still applies.
- **iMac memory (Week 6-7).** 8 GB is tight for RKE2 plus Argo CD, Kyverno, a registry, Prometheus and Loki. Expect to trim (for example, no Argo CD on the target, since Zarf deploys) or set small resource limits.
- **Zarf and Kyverno image verification (Week 6).** Zarf rewrites image references to its own in-cluster registry. Test early that the `verifyImages` policy still admits signed images after the rewrite.

---

## After Week 8 — Phase 2 and 3 skeletons

### Phase 2: Local LLM inference on the platform

- [ ] Choose a small quantized model; serve with vLLM or llama.cpp in a pod
- [ ] Package model and runtime for the airgapped cluster via Zarf
- [ ] KEDA autoscaling on request queue depth
- [ ] OpenTelemetry and Prometheus metrics: latency, tokens per second, queue depth
- [ ] Load test; document cost and latency per million tokens (CPU, then a short rented GPU run)
- [ ] Post: inference platform results

### Phase 3: Reliability layer

- [ ] SLO definitions and burn-rate alerts for the sample app and the inference service
- [ ] Chaos Mesh or Litmus experiments with a postmortem per experiment under `docs/postmortems/`
- [ ] LLM triage agent: retrieval over runbooks and postmortems, with a small evaluation set and recorded accuracy
- [ ] Post: SRE layer results

---

## Ground rules

- Built from scratch on personal hardware.
- No configs, naming, hostnames, or architecture from any employer system appear in code, docs, or posts.
- Secrets, kubeconfigs, key files, and state files are never committed.
- Sample applications are generic (a small web app and a database).

